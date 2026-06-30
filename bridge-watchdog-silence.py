#!/usr/bin/env python3
"""bridge-watchdog-silence.py — issue #265 proposal C.

Sibling supervisor that watches the audit log for `daemon_tick` heartbeat
rows (proposal B, PR #274). If the daemon goes silent — no heartbeat
written within `BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS` (default 600s) —
the supervisor restarts the daemon and emits structured audit rows so the
operator can see the recovery without grepping process state.

The hang vector this defends against is documented in issue #265: a
`tmux send-keys` blocked on a dead Discord SSL pipe left the daemon
process alive but its bash main loop wedged at `__wait4` for 34 hours.
Per-call timeouts (proposal A, PR #279/#281) close the canonical hang
vector; this watchdog is the second line of defence — if a *new* hang
vector slips past the timeout layer, audit silence is the durable signal
and an automated restart contains the blast radius without operator
intervention.

Trust model (issue #591):
    `BRIDGE_DAEMON_PID_FILE` MUST resolve to a path under `BRIDGE_HOME`.
    The watchdog supervises only the daemon launched from the same
    `BRIDGE_HOME` tree; a cross-home configuration (e.g. a dev shell that
    leaked the live host's pid file path while pointing `BRIDGE_HOME` at
    a temp dir) lets a stale watchdog SIGTERM the live daemon. The
    validator at startup (`_validate_cross_home`) refuses to run in that
    shape and exits with code 2, distinct from the normal "no daemon
    running" path.

Usage:
    python3 bridge-watchdog-silence.py run [--once]
    python3 bridge-watchdog-silence.py status
    python3 bridge-watchdog-silence.py cleanup-orphans [--dry-run]

Environment:
    BRIDGE_HOME                                       runtime root
    BRIDGE_AUDIT_LOG                                  audit JSONL path
    BRIDGE_STATE_DIR                                  state dir for cooldown file
    BRIDGE_DAEMON_PID_FILE                            daemon pid file (must be under BRIDGE_HOME)
    BRIDGE_DAEMON_HEARTBEAT_SECONDS                   if 0, watchdog disables itself
    BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS           default 600
    BRIDGE_DAEMON_SILENCE_POLL_INTERVAL_SECONDS       default 60
    BRIDGE_DAEMON_SILENCE_RESTART_COOLDOWN_SECONDS    default 300
    BRIDGE_DAEMON_SILENCE_TAIL_BYTES                  audit tail window (default 4 MiB)
    BRIDGE_DAEMON_SILENCE_RESTART_TIMEOUT_SECONDS     stop+start timeout (default 30)
    BRIDGE_DAEMON_SCRIPT                              override DAEMON_SCRIPT resolution
    BRIDGE_DAEMON_SILENCE_PIDLOCK                     override pidlock path (default state/silence-watchdog.pidlock)
"""

from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
BRIDGE_HOME = Path(os.environ.get("BRIDGE_HOME", Path.home() / ".agent-bridge"))
BRIDGE_STATE_DIR = Path(os.environ.get("BRIDGE_STATE_DIR", BRIDGE_HOME / "state"))
BRIDGE_LOG_DIR = Path(os.environ.get("BRIDGE_LOG_DIR", BRIDGE_HOME / "logs"))
BRIDGE_AUDIT_LOG = Path(
    os.environ.get("BRIDGE_AUDIT_LOG", BRIDGE_LOG_DIR / "audit.jsonl")
)
BRIDGE_DAEMON_PID_FILE = Path(
    os.environ.get("BRIDGE_DAEMON_PID_FILE", BRIDGE_STATE_DIR / "daemon.pid")
)

COOLDOWN_FILE = Path(
    os.environ.get("BRIDGE_DAEMON_SILENCE_COOLDOWN_FILE", BRIDGE_STATE_DIR / "silence-watchdog.json")
)
PIDLOCK_FILE = Path(
    os.environ.get("BRIDGE_DAEMON_SILENCE_PIDLOCK", BRIDGE_STATE_DIR / "silence-watchdog.pidlock")
)


def _default_daemon_script() -> Path:
    """Resolve the canonical daemon script path.

    Issue #800 Track C: the previous default of ``SCRIPT_DIR / "bridge-daemon.sh"``
    permanently bound watchdog instances launched from temp / worktree paths to
    those (often-deleted) paths. Every recovery attempt then exited 127 on
    "No such file or directory" and the live daemon was never restarted.

    Resolution precedence (each step must point at an existing file):

    1. ``BRIDGE_HOME/bridge-daemon.sh`` — the canonical install location.
       This is the path the launchd plist / systemd unit shipped via
       ``scripts/install-watchdog-silence-launchagent.sh`` resolves to.
    2. ``~/.agent-bridge/bridge-daemon.sh`` — documented canonical install
       fallback used ONLY when ``BRIDGE_HOME`` is unset.
    3. ``SCRIPT_DIR / "bridge-daemon.sh"`` — last-resort in-tree development
       fallback so ``python3 bridge-watchdog-silence.py …`` still works when
       run directly out of a source checkout.

    The explicit ``BRIDGE_DAEMON_SCRIPT`` env-var override (handled by the
    caller) wins above all of these and is kept for tests.

    Issue #1860 cross-home hardening: when ``BRIDGE_HOME`` IS set (an
    isolated / test runtime root) we pin resolution INSIDE that home and
    never fall through to the live ``~/.agent-bridge`` install — even if the
    in-home ``bridge-daemon.sh`` does not exist yet. The old behaviour
    (continue to step 2 when ``BRIDGE_HOME/bridge-daemon.sh`` was absent) let
    a watchdog spawned under a temp ``BRIDGE_HOME`` resolve ``DAEMON_SCRIPT``
    to the operator's live daemon and drive a restart against it. The
    ``~/.agent-bridge`` fallback is for the *unset* case only.
    """
    home = os.environ.get("BRIDGE_HOME", "").strip()
    if home:
        # BRIDGE_HOME pins resolution inside the home, full stop. Return the
        # in-home path whether or not it exists yet — never continue to the
        # live ~/.agent-bridge fallback (#1860 cross-home guard).
        return Path(home).expanduser() / "bridge-daemon.sh"
    default_home_candidate = Path.home() / ".agent-bridge" / "bridge-daemon.sh"
    if default_home_candidate.is_file():
        return default_home_candidate
    # Last-resort dev fallback. Production installs should NEVER reach this
    # branch — it indicates the watchdog is running from a non-canonical
    # location (temp dir, worktree, etc.) and is the exact failure class
    # issue #800 / #265 documented. Log a clear warning so operators see
    # the problem rather than silently inheriting the broken default. The
    # module-level `log` is not yet bound at import time when this resolver
    # runs, so use `logging.getLogger` directly — it's the same handler the
    # rest of the module will attach to once `logging.basicConfig` runs.
    fallback = SCRIPT_DIR / "bridge-daemon.sh"
    logging.getLogger("watchdog-silence").warning(
        "DAEMON_SCRIPT resolved via SCRIPT_DIR fallback (%s) — "
        "no BRIDGE_HOME or ~/.agent-bridge install found. "
        "This is the failure mode #800 Track C documented; "
        "set BRIDGE_HOME or install canonically via 'agent-bridge upgrade'.",
        fallback,
    )
    return fallback


DAEMON_SCRIPT = Path(
    os.environ.get("BRIDGE_DAEMON_SCRIPT") or _default_daemon_script()
)


def _validate_cross_home() -> None:
    """Refuse to run if `BRIDGE_DAEMON_PID_FILE` is outside `BRIDGE_HOME`.

    Issue #591 / #592: a watchdog inheriting `BRIDGE_DAEMON_PID_FILE` from a
    parent shell while `BRIDGE_HOME` points at a temp dir will read its own
    (empty) audit log, conclude the live daemon is silent, and SIGTERM the
    live PID. The legitimate use case (a test bridge-home shutting down its
    own daemon) is preserved because that test's pid file lives under its
    own BRIDGE_HOME — only the *cross-home* shape is unsafe.

    `.resolve()` is called on both paths so symlinked BRIDGE_HOME layouts
    (e.g. `~/.agent-bridge` -> `~/.agent-bridge-home`) compare correctly.
    """
    pid_file = BRIDGE_DAEMON_PID_FILE.resolve()
    home = BRIDGE_HOME.resolve()
    try:
        pid_file.relative_to(home)
    except ValueError:
        log.error(
            "refusing to run: BRIDGE_DAEMON_PID_FILE=%s is outside BRIDGE_HOME=%s "
            "(cross-home configuration is unsafe; the watchdog can only supervise "
            "a daemon whose pid file lives under its own BRIDGE_HOME). "
            "Unset BRIDGE_DAEMON_PID_FILE or set BRIDGE_HOME to match.",
            pid_file, home,
        )
        sys.exit(2)  # exit code distinct from normal "no daemon running" paths


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value


HEARTBEAT_INTERVAL = _env_int("BRIDGE_DAEMON_HEARTBEAT_SECONDS", 60)
SILENCE_THRESHOLD = _env_int("BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS", 600)
POLL_INTERVAL = max(5, _env_int("BRIDGE_DAEMON_SILENCE_POLL_INTERVAL_SECONDS", 60))
RESTART_COOLDOWN = _env_int("BRIDGE_DAEMON_SILENCE_RESTART_COOLDOWN_SECONDS", 300)
TAIL_BYTES = max(64 * 1024, _env_int("BRIDGE_DAEMON_SILENCE_TAIL_BYTES", 4 * 1024 * 1024))
RESTART_TIMEOUT = max(5, _env_int("BRIDGE_DAEMON_SILENCE_RESTART_TIMEOUT_SECONDS", 30))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
)
log = logging.getLogger("watchdog-silence")


@dataclass
class TickInfo:
    epoch: float           # last daemon_tick wall-clock epoch (parsed from `ts`)
    age_seconds: float     # now - epoch
    raw_ts: str            # original ISO string, for audit detail


def parse_iso_to_epoch(value: str) -> float | None:
    """Parse the audit `ts` field. Accepts ISO 8601 with offset; treats naive
    timestamps as UTC. Returns None if unparseable."""
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    # Python <3.11 datetime.fromisoformat doesn't accept trailing 'Z'.
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def find_last_daemon_tick(audit_path: Path, tail_bytes: int) -> TickInfo | None:
    """Scan the tail of the audit JSONL and return the latest daemon_tick
    written by `actor=daemon`. Reading just the tail keeps the watchdog
    O(1) regardless of audit-log size; if no daemon_tick appears in the
    window the audit file is either fresh or so dominated by other events
    that we already need to grow the tail (logged as a warning so the
    operator can bump BRIDGE_DAEMON_SILENCE_TAIL_BYTES rather than have us
    silently treat that as silence)."""
    try:
        size = audit_path.stat().st_size
    except FileNotFoundError:
        return None
    if size == 0:
        return None

    read_from = max(0, size - tail_bytes)
    with audit_path.open("rb") as handle:
        if read_from > 0:
            handle.seek(read_from)
            handle.readline()  # discard partial line at the seek boundary
        chunk = handle.read()

    last: TickInfo | None = None
    now = time.time()
    for raw in chunk.splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if not isinstance(record, dict):
            continue
        if record.get("actor") != "daemon" or record.get("action") != "daemon_tick":
            continue
        epoch = parse_iso_to_epoch(record.get("ts", ""))
        if epoch is None:
            continue
        if last is None or epoch > last.epoch:
            last = TickInfo(epoch=epoch, age_seconds=max(0.0, now - epoch), raw_ts=record.get("ts", ""))

    if last is None and read_from > 0:
        log.warning(
            "no daemon_tick in last %d bytes of %s — consider raising "
            "BRIDGE_DAEMON_SILENCE_TAIL_BYTES",
            tail_bytes, audit_path,
        )
    return last


def read_cooldown() -> float:
    if not COOLDOWN_FILE.exists():
        return 0.0
    try:
        data = json.loads(COOLDOWN_FILE.read_text(encoding="utf-8"))
        return float(data.get("last_restart_epoch", 0.0))
    except (json.JSONDecodeError, OSError, ValueError, TypeError):
        return 0.0


def write_cooldown(epoch: float, detail: dict) -> None:
    COOLDOWN_FILE.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "last_restart_epoch": epoch,
        "last_restart_iso": datetime.fromtimestamp(epoch, tz=timezone.utc)
        .astimezone()
        .isoformat(timespec="seconds"),
        "detail": detail,
    }
    tmp = COOLDOWN_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(COOLDOWN_FILE)


def daemon_recorded_pid() -> int | None:
    if not BRIDGE_DAEMON_PID_FILE.exists():
        return None
    try:
        text = BRIDGE_DAEMON_PID_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not text:
        return None
    try:
        return int(text)
    except ValueError:
        return None


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Signal would land — treat as alive.
        return True
    except OSError:
        return False
    return True


def acquire_pidlock() -> "tuple[object, Path] | None":
    """Acquire an exclusive non-blocking flock on the watchdog pidlock.

    Issue #800 Track C compounding factor: multiple watchdog instances
    accumulated on the same host (10 concurrent on the affected install),
    each looping detection without ever advancing ``last_restart_epoch``.
    A pidlock at ``state/silence-watchdog.pidlock`` makes ``run`` self-
    deduplicate so the second-and-later invocations exit cleanly with a
    log line pointing at the holder.

    Returns ``(lock_fd, lock_path)`` on success, ``None`` if another
    instance already holds the lock (caller should exit 0).

    The lock file path is resolved from ``$BRIDGE_HOME/state/`` (or the
    explicit ``BRIDGE_DAEMON_SILENCE_PIDLOCK`` override) — never
    ``SCRIPT_DIR``, so concurrent watchdogs launched from different temp
    paths still contend on the same lockfile.
    """
    lock_path = PIDLOCK_FILE
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        log.error("pidlock parent mkdir failed: %s", exc)
        return None

    # Open for read+write (create if missing) so we can both flock and
    # write the holder pid for diagnostics.
    try:
        fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as exc:
        log.error("pidlock open failed for %s: %s", lock_path, exc)
        return None

    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # Someone else holds it. Read the pid for the log message and exit
        # cleanly — concurrent watchdogs are an expected condition on hosts
        # with stale launches, not an error.
        try:
            with open(str(lock_path), "r", encoding="utf-8") as handle:
                other = handle.read().strip() or "unknown"
        except OSError:
            other = "unknown"
        finally:
            os.close(fd)
        log.info(
            "another bridge-watchdog-silence instance already running "
            "(holder_pid=%s lock=%s) — exiting cleanly",
            other, lock_path,
        )
        return None

    # We hold the lock. Stamp our pid so a future contender can see who
    # owns it. truncate-then-write keeps the file size in sync with the
    # current holder rather than appending across handoffs.
    try:
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode("utf-8"))
        os.fsync(fd)
    except OSError as exc:
        log.warning("pidlock write failed (lock still held): %s", exc)

    return (fd, lock_path)


def release_pidlock(handle: "tuple[object, Path] | None") -> None:
    """Release the watchdog pidlock acquired by :func:`acquire_pidlock`."""
    if handle is None:
        return
    fd, lock_path = handle
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    # We deliberately leave the lock file on disk so the next instance can
    # contend on the same inode without a recreate race. Stale pid bytes
    # are harmless (re-stamped on next acquire).
    _ = lock_path  # keep the path available for callers that want to log it


def emit_audit(action: str, detail: dict) -> None:
    """Write an audit row via bridge-audit.py so we share the hash chain
    and rotation logic with every other bridge writer."""
    audit_script = SCRIPT_DIR / "bridge-audit.py"
    cmd = [
        sys.executable, str(audit_script), "write",
        "--file", str(BRIDGE_AUDIT_LOG),
        "--actor", "daemon",
        "--action", action,
        "--target", "daemon",
    ]
    for key, value in detail.items():
        cmd.extend(["--detail", f"{key}={value}"])
    try:
        subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=10)
    except (subprocess.SubprocessError, OSError) as exc:
        # Audit write failure is observability — never let it crash the
        # supervisor loop. Stderr stays in launchagent log via stdout/stderr
        # capture by the parent.
        log.error("audit write failed for %s: %s", action, exc)


# Stderr preview cap (bytes) for the persisted state file. The full stderr
# block goes to the watchdog log unconditionally; the JSON state field is
# capped so a runaway resolver message can't bloat silence-watchdog.json.
STDERR_PREVIEW_MAX = 500


def _stderr_preview(output: str) -> str:
    """Trim and single-line-escape a captured stderr block for audit/state.

    Multi-line resolver die messages are valuable in the watchdog log, but
    the audit `--detail key=value` channel and the JSON state file are
    easier to grep / round-trip when each preview is a single line. We
    replace newlines with the literal `\\n` two-char sequence and cap to
    `STDERR_PREVIEW_MAX` bytes so the persisted size stays bounded.
    """
    return output.strip().replace("\n", "\\n")[:STDERR_PREVIEW_MAX]


def _indent_block(text: str, prefix: str = "    ") -> str:
    """Indent every line of `text` with `prefix` for readable log output."""
    if not text:
        return ""
    return "\n".join(prefix + line for line in text.rstrip("\n").splitlines())


def _classify_resolver_die(stderr_text: str) -> str:
    """Map a `bridge-layout-resolver.sh` `bridge_die` stderr block to a
    short identifier of which die path fired.

    Issue #946 L3: every silence-watchdog `daemon stop` failure from
    2026-05-15 onward surfaced the same truncated v0.8.0 ACL-removal
    sentence (the last line of the multi-line die message), making
    post-mortem triage impossible without re-running the wedged invocation.
    The full stderr already carries a `current_layout=` discriminator;
    this helper substring-matches that discriminator against the three
    known die paths in `lib/bridge-layout-resolver.sh` so the audit row
    records which path fired without a parse pass.

    Path map (verified against `lib/bridge-layout-resolver.sh` 2026-05-17):
      - `current_layout=legacy` / `current_layout=v1` -> marker says
        marker-pinned-legacy (line 384).
      - `current_layout=markerless(existing-install)` -> evidence-based
        markerless existing install (line 406).
      - `current_layout=markerless(...)` (anything else, typically
        `fresh-install-candidate` or `invalid-marker(fallback)`) ->
        evidence-based markerless fresh-candidate (line 439).
      - `ACL-based isolation` present without any of the above -> some
        other v0.8.0 hard-cut surface we have not catalogued yet; caller
        should look at the full stderr block.
      - none of the above -> `other` (not a resolver die — could be a
        permission error, missing pid file, timeout, etc.).

    Returns a short token suitable for use as an audit detail value.
    """
    if not stderr_text:
        return "other"
    # Match the `current_layout=` discriminator first — it's emitted by all
    # three resolver die paths and is the only field that disambiguates.
    if "current_layout=markerless(existing-install)" in stderr_text:
        return "markerless-existing (line 406)"
    if "current_layout=markerless(" in stderr_text:
        # Catches `fresh-install-candidate`, `invalid-marker(fallback)`,
        # `missing-marker(existing)`, and any future markerless source.
        return "markerless-fresh-candidate (line 439)"
    if "current_layout=legacy" in stderr_text or "current_layout=v1" in stderr_text:
        return "marker-legacy (line 384)"
    # No `current_layout=` line, but the ACL-removal sentence is present —
    # this is a v0.8.0 hard-cut surface we don't recognize. Surface that
    # ambiguity clearly so post-mortem readers know to read the full
    # stderr block (preserved in the log) rather than trust the label.
    if "ACL-based isolation" in stderr_text:
        return "v0.8.0-isolation-hard-cut (line unknown — see full stderr)"
    return "other"


def run_daemon_command(*verb_args: str) -> tuple[int, str]:
    """Run `bash bridge-daemon.sh <verb_args>` with a hard timeout. Returns
    (exit_code, full-combined-output) so callers can both log the entire
    block (grep-able) and classify the failure mode.

    Issue #946 L3: the previous implementation truncated the captured
    output to `splitlines()[-1]`, which discarded the multi-line resolver
    die message and left every wedge surfacing the same generic ACL line.
    Full capture is cheap (the daemon stop/start output is bounded by the
    `RESTART_TIMEOUT` window) and is the only way to identify which die
    path fired in a post-mortem.
    """
    bash = os.environ.get("BRIDGE_BASH_BIN", "bash")
    cmd = [bash, str(DAEMON_SCRIPT), *verb_args]
    label = " ".join(verb_args)
    try:
        result = subprocess.run(
            cmd,
            capture_output=True, text=True, timeout=RESTART_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return 124, f"bridge-daemon.sh {label} timed out after {RESTART_TIMEOUT}s"
    except OSError as exc:
        return 127, f"bridge-daemon.sh {label} spawn failed: {exc}"
    output = (result.stdout or "") + (result.stderr or "")
    return result.returncode, output


def _daemon_is_launchd_managed() -> bool:
    """True only on a launchd-MANAGED macOS install (mirrors the Bash
    ``_bridge_daemon_launchd_label`` contract in lib/bridge-daemon-control.sh).

    Launchd-managed ⇔ Darwin AND a launchd label resolves: either the
    installer marker ``state/launchagent.config`` exports
    ``BRIDGE_LAUNCHAGENT_LABEL``, or the env default label has an existing
    plist on disk. A macOS *nohup* daemon (no marker, no plist) is NOT
    launchd-managed — there the recorded pid is a plain process we own, so
    the escalation MUST SIGKILL it (otherwise the re-arm's stop phase can
    block on the same wedged pid and the escalation achieves nothing,
    leaving the old fail-open behaviour). Linux (systemd/nohup) is never
    launchd-managed. Kept as a seam so both branches are testable without a
    real launchd job.
    """
    if sys.platform != "darwin":
        return False
    config_path = BRIDGE_STATE_DIR / "launchagent.config"
    if config_path.is_file():
        try:
            for line in config_path.read_text(encoding="utf-8").splitlines():
                key, _, value = line.partition("=")
                if key.strip() == "BRIDGE_LAUNCHAGENT_LABEL" and value.strip():
                    return True
        except OSError:
            pass
    label = os.environ.get("BRIDGE_DAEMON_LAUNCHAGENT_LABEL", "").strip()
    plist = os.environ.get("BRIDGE_DAEMON_LAUNCHAGENT_PLIST", "").strip()
    return bool(label and plist and Path(plist).is_file())


def _daemon_owner_record() -> dict:
    """Parse the daemon singleton owner record (``$PID_FILE.owner``) into a
    ``key=value`` dict. The daemon writes (pid, cmdline, start_time,
    generation) there under the held lock
    (lib/bridge-daemon-control.sh::_bridge_daemon_singleton_write_owner).
    Empty dict when absent/unreadable.
    """
    owner_path = Path(f"{BRIDGE_DAEMON_PID_FILE}.owner")
    if not owner_path.is_file():
        return {}
    record: dict = {}
    try:
        for line in owner_path.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                record[key.strip()] = value.strip()
    except OSError:
        return {}
    return record


def _proc_start_time(pid: int) -> str:
    """Live wall-clock start time of <pid> via ``ps -o lstart=``, whitespace
    collapsed to a single-line token (mirrors the Bash
    ``_bridge_daemon_proc_start_time``). Empty string on any failure.

    Two processes that recycle the same pid number have DIFFERENT lstart
    values, so a recorded (pid, start_time) pair uniquely pins one process
    GENERATION — the proof that lets us refuse to SIGKILL a recycled pid.
    """
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart="],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return ""
    return " ".join((result.stdout or "").split())


def _recorded_daemon_pid_provenance_ok(pid: int) -> bool:
    """Strict provenance gate for the escalation SIGKILL — mirrors the
    daemon singleton's evict-proof (lib/bridge-daemon-control.sh:1502-1531).

    The recorded pid is the daemon's own claim, but a stale pid file can
    outlive the daemon and get reused by an unrelated (or look-alike)
    process. Before this watchdog — the last automated line — SIGKILLs
    anything, require POSITIVE proof the pid is the SAME daemon generation
    we recorded, ALL of:

      1. pid alive,
      2. live cmdline contains ``bridge-daemon.sh run`` (the daemon run
         shape, not merely the filename — a `restart`/look-alike invocation
         is rejected),
      3. the owner record's recorded pid == this pid AND its recorded
         ``start_time`` matches the live ``ps -o lstart=`` token (a recycled
         pid has a different start time, so it is NOT the holder).

    Any missing/unreadable input → fail closed (no kill). This is the exact
    standard the singleton uses before TERM/KILLing a predecessor.
    """
    if not pid_alive(pid):
        return False
    cmdline = _watchdog_cmdline(pid)
    if "bridge-daemon.sh run" not in cmdline:
        return False
    record = _daemon_owner_record()
    recorded_pid = record.get("pid", "")
    recorded_start = record.get("start_time", "")
    if not recorded_pid or recorded_pid != str(pid):
        return False
    live_start = _proc_start_time(pid)
    return bool(recorded_start and live_start and recorded_start == live_start)


def _escalate_hung_restart(restart_code: int, reason_detail: dict) -> bool:
    """Escalate a hung/failed `restart --force` (rc 124 and any non-0/non-2)
    instead of only cooling down for ``RESTART_COOLDOWN`` seconds.

    The watchdog is the last automated recovery line; a bare 300s cooldown
    on a wedged restart leaves the daemon down for the full window. This
    drives a harder recovery:

    1. SIGKILL the recorded wedged daemon pid — but ONLY on a non-launchd
       host. On macOS launchd installs the recorded pid is launchd's OWN
       supervised job: an out-of-band SIGKILL would race launchd's
       KeepAlive respawn (kill → KeepAlive relaunch → we kill the fresh
       one). There the OS-init re-arm (`restart --force` → ``launchctl
       kickstart -k``) already kills+respawns launchd's instance
       atomically, so we skip the manual kill and let the re-arm own it.
       The kill is pid-alive AND recorded-pid-provenance guarded so we can
       never signal an unrelated/recycled pid.
    2. Drive ONE bounded OS-init re-arm via the same `restart --force`
       verb (launchd kickstart on macOS / stop+start on Linux). Hard
       single-shot ceiling — we never loop kill→rearm.

    Returns True when the re-arm produced a live daemon (caller records a
    ``restarted`` outcome + cooldown), False when escalation also failed
    (caller falls back to the existing ``restart_failed`` 300s cooldown).
    """
    is_launchd = _daemon_is_launchd_managed()
    recorded_pid = daemon_recorded_pid()

    killed_pid: int | None = None
    kill_skip_reason = ""
    if is_launchd:
        # launchd owns the pid — never out-of-band SIGKILL (KeepAlive race).
        kill_skip_reason = "launchd_owns_pid_rearm_handles_kill"
    elif recorded_pid is None:
        kill_skip_reason = "no_recorded_pid"
    elif not _recorded_daemon_pid_provenance_ok(recorded_pid):
        # Pid gone or cmdline no longer names the daemon → nothing safe to
        # kill; the re-arm's own start path owns recovery.
        kill_skip_reason = "recorded_pid_not_live_daemon"
    else:
        try:
            os.kill(recorded_pid, 9)
            killed_pid = recorded_pid
            log.warning(
                "escalate: SIGKILL wedged daemon pid=%s after hung restart "
                "(exit=%s)", recorded_pid, restart_code,
            )
        except ProcessLookupError:
            kill_skip_reason = "pid_vanished_before_kill"
        except OSError as exc:
            kill_skip_reason = f"sigkill_failed:{exc}"
            log.warning("escalate: SIGKILL pid=%s failed: %s", recorded_pid, exc)

    # ONE bounded OS-init re-arm. No retry loop — the cooldown owns the
    # next attempt if this fails.
    rearm_code, rearm_output = run_daemon_command("restart", "--force")
    rearm_pid = daemon_recorded_pid() or 0
    rearm_ok = rearm_code == 0 and rearm_pid > 0 and pid_alive(rearm_pid)

    emit_audit(
        "daemon_silence_restart_escalated",
        {
            "outcome": "escalated_restarted" if rearm_ok else "escalated_failed",
            "restart_exit": restart_code,
            "killed_pid": killed_pid if killed_pid is not None else "",
            "kill_skipped": kill_skip_reason,
            "launchd": "1" if is_launchd else "0",
            "rearm_exit": rearm_code,
            "rearm_pid": rearm_pid,
            **reason_detail,
        },
    )
    if rearm_ok:
        log.info(
            "escalate: daemon re-armed after hung restart (killed_pid=%s "
            "launchd=%s new_pid=%s)",
            killed_pid if killed_pid is not None else "-", is_launchd, rearm_pid,
        )
    else:
        log.error(
            "escalate: OS-init re-arm also failed (exit=%s):\n%s",
            rearm_code, _indent_block(rearm_output),
        )
    return rearm_ok


def attempt_restart(reason_detail: dict) -> None:
    """Restart the daemon via the single `restart` verb and emit the
    structured audit trail.

    Issue #1463: route through `bridge-daemon.sh restart --force` instead
    of a direct `stop --force` + `start`. On macOS launchd installs the
    `restart` verb cycles launchd's OWN supervised job
    (`launchctl kickstart -k`) so the fresh daemon holds the singleton lock
    inside launchd's process tree — KeepAlive then has nothing to thrash
    against. A direct out-of-band stop+start (the old code) established a
    NON-launchd lock holder and re-armed the KeepAlive vs lock thrash. On
    Linux (systemd/nohup) `restart` falls through to the same internal
    stop+start it always did, so the resolver_die classification surface
    below is preserved on the host where it matters.
    """
    emit_audit("daemon_silence_detected", reason_detail)
    log.warning("daemon silence detected — %s", reason_detail)

    # --force: the silence watchdog only fires on a wedged/silent daemon.
    # Bypass the issue #314/#315 active-agent guard so a stuck daemon can
    # still be restarted on a host with running agents.
    restart_code, restart_output = run_daemon_command("restart", "--force")

    # rc=2 from the restart verb means the launchd-aware primitive REFUSED
    # to kickstart because the live lock holder is not launchd's job pid (an
    # existing out-of-band split). Surface it distinctly — a one-time
    # operator reconcile (`bridge-daemon.sh stop --force`) is required;
    # auto-restarting here would not help and the cooldown prevents a loop.
    if restart_code == 2:
        emit_audit(
            "daemon_silence_restart_attempted",
            {
                "outcome": "restart_refused",
                "restart_exit": restart_code,
                "reason": "launchd_out_of_band_split",
                **reason_detail,
            },
        )
        log.error(
            "daemon restart REFUSED — out-of-band launchd split; run "
            "'bridge-daemon.sh stop --force' once to reconcile:\n%s",
            _indent_block(restart_output),
        )
        write_cooldown(time.time(), {
            "outcome": "restart_refused",
            "restart_exit": restart_code,
            "reason": "launchd_out_of_band_split",
        })
        return

    if restart_code != 0:
        # Issue #2208: a hung restart (rc 124) — or any other non-0/non-2
        # failure — used to write the 300s cooldown and return, parking the
        # daemon DOWN for the full window with no harder kill or OS-init
        # re-arm. The watchdog is the last automated recovery line, so
        # escalate first: SIGKILL the wedged pid (non-launchd hosts only —
        # launchd's KeepAlive owns the kill there) then drive ONE bounded
        # `restart --force` re-arm. Only fall back to the cooldown below
        # when the escalation also fails to bring a live daemon back.
        if _escalate_hung_restart(restart_code, reason_detail):
            new_pid = daemon_recorded_pid() or 0
            write_cooldown(time.time(), {
                "outcome": "restarted",
                "via": "escalation",
                "restart_exit": restart_code,
                "new_pid": new_pid,
            })
            return

        # Issue #946 L3: classify which resolver die path fired (when the
        # failure was a v0.8.0 isolation hard-cut) and quote the full
        # stderr block in the watchdog log so post-mortem readers can
        # disambiguate `marker-legacy` / `markerless-existing` /
        # `markerless-fresh-candidate` without re-running the wedge.
        restart_resolver_die = _classify_resolver_die(restart_output)
        restart_preview = _stderr_preview(restart_output)
        emit_audit(
            "daemon_silence_restart_attempted",
            {
                "outcome": "restart_failed",
                "restart_exit": restart_code,
                "restart_resolver_die": restart_resolver_die,
                "restart_msg": restart_preview,
                **reason_detail,
            },
        )
        log.error(
            "daemon restart failed (exit=%s, resolver_die=%s):\n%s",
            restart_code, restart_resolver_die, _indent_block(restart_output),
        )
        # Cooldown is set even on failure so we don't loop on a permanently
        # broken daemon. Persist the resolver_die classification and the
        # stderr preview in the JSON state so an operator (or future
        # diagnosis pass) can grep `silence-watchdog.json` and immediately
        # learn which die path fired without re-running anything.
        write_cooldown(time.time(), {
            "outcome": "restart_failed",
            "restart_exit": restart_code,
            "resolver_die": restart_resolver_die,
            "stderr_preview": restart_preview,
        })
        return

    new_pid = daemon_recorded_pid() or 0
    emit_audit(
        "daemon_silence_restart_attempted",
        {"outcome": "restarted", "new_pid": new_pid, **reason_detail},
    )
    log.info("daemon restarted after silence (new pid=%s)", new_pid)
    write_cooldown(time.time(), {"outcome": "restarted", "new_pid": new_pid})


def tick(now: float | None = None) -> str:
    """One supervision pass. Returns a short string explaining the action
    taken (used by `--once` callers and tests)."""
    if HEARTBEAT_INTERVAL <= 0:
        return "skip:heartbeat_disabled"

    last = find_last_daemon_tick(BRIDGE_AUDIT_LOG, TAIL_BYTES)
    if last is None:
        # No tick ever — fresh install or audit log truncated. Nothing to
        # compare against, so we let the system warm up rather than restart
        # a daemon that may simply not have written its first tick yet.
        return "skip:no_tick_yet"

    now = time.time() if now is None else now
    age = max(0.0, now - last.epoch)
    if age <= SILENCE_THRESHOLD:
        return f"ok:age={age:.0f}s"

    pid = daemon_recorded_pid()
    if pid is None or not pid_alive(pid):
        # Nothing to restart. The launchd/systemd respawn path or the next
        # `bridge-daemon.sh start` from anywhere else owns recovery here.
        emit_audit(
            "daemon_silence_detected",
            {
                "age_seconds": int(age),
                "threshold_seconds": SILENCE_THRESHOLD,
                "last_tick_ts": last.raw_ts,
                "outcome": "skipped_no_running_daemon",
                "recorded_pid": str(pid) if pid is not None else "",
            },
        )
        return "skip:daemon_not_running"

    last_restart = read_cooldown()
    if last_restart and (now - last_restart) < RESTART_COOLDOWN:
        cooldown_remaining = int(RESTART_COOLDOWN - (now - last_restart))
        emit_audit(
            "daemon_silence_detected",
            {
                "age_seconds": int(age),
                "threshold_seconds": SILENCE_THRESHOLD,
                "last_tick_ts": last.raw_ts,
                "outcome": "cooldown_hot",
                "cooldown_remaining_seconds": cooldown_remaining,
            },
        )
        return f"skip:cooldown_remaining={cooldown_remaining}s"

    attempt_restart(
        {
            "age_seconds": int(age),
            "threshold_seconds": SILENCE_THRESHOLD,
            "last_tick_ts": last.raw_ts,
            "daemon_pid": pid,
        }
    )
    return "restart_attempted"


def cmd_run(args: argparse.Namespace) -> int:
    # Issue #800 Track C: pidlock before any work so a second concurrent
    # `run` (the common orphan-accumulation shape) exits cleanly instead
    # of looping detections that fight for the same recovery cooldown.
    lock_handle = acquire_pidlock()
    if lock_handle is None:
        return 0
    try:
        if args.once:
            outcome = tick()
            log.info("once outcome: %s", outcome)
            return 0

        log.info(
            "silence watchdog started (threshold=%ds poll=%ds cooldown=%ds heartbeat=%ds daemon_script=%s)",
            SILENCE_THRESHOLD, POLL_INTERVAL, RESTART_COOLDOWN, HEARTBEAT_INTERVAL,
            DAEMON_SCRIPT,
        )
        while True:
            try:
                tick()
            except Exception as exc:  # noqa: BLE001 — supervisor must not die on any cycle error
                log.error("watchdog cycle error: %s", exc)
            time.sleep(POLL_INTERVAL)
    finally:
        release_pidlock(lock_handle)


def cmd_status(args: argparse.Namespace) -> int:
    print(f"audit_log: {BRIDGE_AUDIT_LOG}")
    print(f"daemon_pid_file: {BRIDGE_DAEMON_PID_FILE}")
    print(f"daemon_script: {DAEMON_SCRIPT} (exists={DAEMON_SCRIPT.is_file()})")
    print(f"pidlock: {PIDLOCK_FILE}")
    print(f"heartbeat_interval_seconds: {HEARTBEAT_INTERVAL}")
    print(f"silence_threshold_seconds: {SILENCE_THRESHOLD}")
    print(f"poll_interval_seconds: {POLL_INTERVAL}")
    print(f"restart_cooldown_seconds: {RESTART_COOLDOWN}")
    last = find_last_daemon_tick(BRIDGE_AUDIT_LOG, TAIL_BYTES)
    if last is None:
        print("last_daemon_tick: (none in tail window)")
        print("last_detection_epoch: (none)")
    else:
        print(f"last_daemon_tick: {last.raw_ts} (age={int(last.age_seconds)}s)")
        if last.age_seconds > SILENCE_THRESHOLD:
            print(f"last_detection_epoch: {last.epoch:.0f} (silence age={int(last.age_seconds)}s)")
        else:
            print("last_detection_epoch: (none — within threshold)")
    cooldown_epoch = read_cooldown()
    if cooldown_epoch:
        age = int(time.time() - cooldown_epoch)
        print(f"last_restart_epoch: {cooldown_epoch} (age={age}s)")
    else:
        print("last_restart_epoch: (never)")
    pid = daemon_recorded_pid()
    if pid is None:
        print("daemon: (no pid file)")
    else:
        print(f"daemon: pid={pid} alive={pid_alive(pid)}")
    # Surface the watchdog's own running instance so daemon-status callers
    # can answer "is the watchdog itself up?" without an extra pgrep.
    watchdog_pid = _read_pidlock_holder()
    if watchdog_pid:
        alive = pid_alive(watchdog_pid)
        print(f"watchdog: pid={watchdog_pid} alive={alive}")
    else:
        print("watchdog: (not running — no pidlock holder)")
    return 0


def _read_pidlock_holder() -> int | None:
    """Read the pid recorded inside the watchdog pidlock, if any.

    Returns ``None`` if the lockfile is absent, empty, or unparseable.
    Note this does NOT prove the holder is still alive — callers should
    cross-check with :func:`pid_alive`.
    """
    try:
        text = PIDLOCK_FILE.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, OSError):
        return None
    if not text:
        return None
    try:
        return int(text.splitlines()[0].strip())
    except (ValueError, IndexError):
        return None


def _watchdog_cmdline(pid: int) -> str:
    """Return the command line of pid <pid>, empty string on any failure.

    Uses ``ps -p <pid> -o command=`` which is portable across macOS and
    Linux; ``/proc/<pid>/cmdline`` would be Linux-only.
    """
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "command="],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return ""
    return (result.stdout or "").strip()


def _process_ppid(pid: int) -> int | None:
    """Return the parent pid of <pid>, ``None`` on failure.

    Uses ``ps -p <pid> -o ppid=`` for cross-platform portability. A ppid
    of 1 indicates the process was reparented to init/launchd, the usual
    fingerprint of an orphan watchdog whose owning session is gone.
    """
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "ppid="],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    text = (result.stdout or "").strip()
    if not text:
        return None
    try:
        return int(text.split()[0])
    except (ValueError, IndexError):
        return None


def _canonical_watchdog_script_paths() -> "list[Path]":
    """Return the set of paths a *non-orphan* watchdog should be running from.

    Anything outside this set, with ppid=1, is an orphan candidate. The
    BRIDGE_DAEMON_SCRIPT env-var override is intentionally read here
    because operators with test rigs that legitimately run the watchdog
    out of a custom path can extend the allow-list.
    """
    canonical: list[Path] = []
    seen: set[str] = set()
    home = os.environ.get("BRIDGE_HOME", "").strip()
    if home:
        candidate = Path(home).expanduser() / "bridge-watchdog-silence.py"
        seen.add(str(candidate.resolve()) if candidate.exists() else str(candidate))
        canonical.append(candidate)
    default_home = Path.home() / ".agent-bridge" / "bridge-watchdog-silence.py"
    key = str(default_home.resolve()) if default_home.exists() else str(default_home)
    if key not in seen:
        canonical.append(default_home)
        seen.add(key)
    override = os.environ.get("BRIDGE_DAEMON_SCRIPT", "").strip()
    if override:
        # When operators pin DAEMON_SCRIPT, treat the sibling watchdog
        # script next to it as canonical too.
        sibling = Path(override).expanduser().parent / "bridge-watchdog-silence.py"
        skey = str(sibling.resolve()) if sibling.exists() else str(sibling)
        if skey not in seen:
            canonical.append(sibling)
            seen.add(skey)
    return canonical


def cmd_cleanup_orphans(args: argparse.Namespace) -> int:
    """Find + reap orphan watchdog instances launched from non-canonical paths.

    Issue #800 Track C compounding factor: the affected install had 10
    concurrent watchdog instances, all from worktree / temp paths, none
    of which could recover the live daemon. None had a parent in their
    original session — they were all reparented to launchd (ppid=1).

    Reaping policy:

    1. ``pgrep -fl bridge-watchdog-silence.py`` to discover candidates.
    2. For each, read the command line. If the script path is in the
       canonical allow-list (``$BRIDGE_HOME`` or ``~/.agent-bridge`` or
       the ``BRIDGE_DAEMON_SCRIPT`` sibling) we skip — that's our own
       canonical instance, not an orphan.
    3. If ppid=1 (reparented to init/launchd), SIGTERM, sleep 2s, then
       SIGKILL if still alive. Skip non-orphans (ppid != 1) to avoid
       killing a fixer's own live test invocation.

    With ``--dry-run``, prints what it would kill without sending signals.
    Idempotent — running again after a clean sweep is a no-op.
    """
    dry_run = bool(getattr(args, "dry_run", False))
    self_pid = os.getpid()
    try:
        result = subprocess.run(
            ["pgrep", "-fl", "bridge-watchdog-silence.py"],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        log.error("pgrep failed: %s", exc)
        return 1

    candidates: list[tuple[int, str]] = []
    for line in (result.stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        head, _, rest = line.partition(" ")
        try:
            pid = int(head)
        except ValueError:
            continue
        if pid == self_pid:
            continue
        candidates.append((pid, rest))

    if not candidates:
        log.info("cleanup-orphans: no watchdog instances found")
        return 0

    canonical_paths = _canonical_watchdog_script_paths()
    canonical_resolved = set()
    for p in canonical_paths:
        try:
            canonical_resolved.add(str(p.resolve()))
        except OSError:
            canonical_resolved.add(str(p))

    killed = 0
    skipped = 0
    for pid, cmdline in candidates:
        cmdline_full = _watchdog_cmdline(pid) or cmdline
        # Extract the script path from the cmdline. The shape is normally
        # `python3 /some/path/bridge-watchdog-silence.py run` — find the
        # first token ending in bridge-watchdog-silence.py.
        script_path: Path | None = None
        for token in cmdline_full.split():
            if token.endswith("bridge-watchdog-silence.py"):
                script_path = Path(token)
                break
        if script_path is None:
            log.info(
                "cleanup-orphans: skip pid=%s (cannot parse script path from cmdline=%r)",
                pid, cmdline_full,
            )
            skipped += 1
            continue

        try:
            resolved = str(script_path.resolve())
        except OSError:
            resolved = str(script_path)

        if resolved in canonical_resolved:
            log.info(
                "cleanup-orphans: skip pid=%s (canonical path=%s)",
                pid, resolved,
            )
            skipped += 1
            continue

        ppid = _process_ppid(pid)
        if ppid != 1:
            log.info(
                "cleanup-orphans: skip pid=%s (non-orphan ppid=%s path=%s)",
                pid, ppid, resolved,
            )
            skipped += 1
            continue

        if dry_run:
            log.info(
                "cleanup-orphans: would TERM pid=%s (orphan path=%s ppid=%s)",
                pid, resolved, ppid,
            )
            killed += 1
            continue

        log.info(
            "cleanup-orphans: SIGTERM pid=%s (orphan path=%s ppid=%s)",
            pid, resolved, ppid,
        )
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            continue
        except OSError as exc:
            log.warning("cleanup-orphans: SIGTERM pid=%s failed: %s", pid, exc)
            continue
        # Grace period, then SIGKILL if still alive.
        time.sleep(2)
        if pid_alive(pid):
            log.warning("cleanup-orphans: SIGKILL pid=%s (TERM grace expired)", pid)
            try:
                os.kill(pid, 9)
            except (ProcessLookupError, OSError):
                pass
        killed += 1

    log.info(
        "cleanup-orphans: %s %d orphan(s), skipped %d canonical/non-orphan instance(s)",
        "would kill" if dry_run else "killed", killed, skipped,
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="bridge-watchdog-silence.py")
    sub = parser.add_subparsers(dest="command", required=True)

    run_p = sub.add_parser("run")
    run_p.add_argument("--once", action="store_true", help="run a single tick and exit")
    run_p.set_defaults(handler=cmd_run)

    status_p = sub.add_parser("status")
    status_p.set_defaults(handler=cmd_status)

    cleanup_p = sub.add_parser(
        "cleanup-orphans",
        help="Find + reap orphan watchdog instances (#800 Track C).",
    )
    cleanup_p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be killed without sending signals.",
    )
    cleanup_p.set_defaults(handler=cmd_cleanup_orphans)

    args = parser.parse_args()
    # Issue #591: refuse to run with a cross-home pid file before any state
    # read or audit peek so a leaked-env orphan terminates itself instead of
    # cross-home killing the live daemon. cleanup-orphans does not read the
    # daemon pid file (it operates on its own pgrep results) so it is exempt
    # — and the exemption matters because cleanup is most useful precisely
    # when the operator is recovering from a cross-home env leak.
    if args.command != "cleanup-orphans":
        _validate_cross_home()
    return int(args.handler(args))


if __name__ == "__main__":
    sys.exit(main())
