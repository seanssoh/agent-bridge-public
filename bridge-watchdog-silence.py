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
"""

from __future__ import annotations

import argparse
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
DAEMON_SCRIPT = Path(
    os.environ.get("BRIDGE_DAEMON_SCRIPT", SCRIPT_DIR / "bridge-daemon.sh")
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


def run_daemon_command(*verb_args: str) -> tuple[int, str]:
    """Run `bash bridge-daemon.sh <verb_args>` with a hard timeout. Returns
    (exit_code, last-line-of-output) so the audit row can record why a
    restart attempt failed."""
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
    last = output.strip().splitlines()[-1] if output.strip() else ""
    return result.returncode, last


def attempt_restart(reason_detail: dict) -> None:
    """Stop + start the daemon and emit the structured audit trail."""
    emit_audit("daemon_silence_detected", reason_detail)
    log.warning("daemon silence detected — %s", reason_detail)

    # --force: the silence watchdog only fires on a wedged/silent daemon.
    # Bypass the issue #314/#315 active-agent guard so a stuck daemon can
    # still be restarted on a host with running agents.
    stop_code, stop_msg = run_daemon_command("stop", "--force")
    if stop_code != 0:
        emit_audit(
            "daemon_silence_restart_attempted",
            {
                "outcome": "stop_failed",
                "stop_exit": stop_code,
                "stop_msg": stop_msg[:200],
                **reason_detail,
            },
        )
        log.error("daemon stop failed (exit=%s): %s", stop_code, stop_msg)
        # Cooldown is set even on failure so we don't loop on a permanently
        # broken daemon.
        write_cooldown(time.time(), {"outcome": "stop_failed", "stop_exit": stop_code})
        return

    start_code, start_msg = run_daemon_command("start")
    if start_code != 0:
        emit_audit(
            "daemon_silence_restart_attempted",
            {
                "outcome": "start_failed",
                "start_exit": start_code,
                "start_msg": start_msg[:200],
                **reason_detail,
            },
        )
        log.error("daemon start failed (exit=%s): %s", start_code, start_msg)
        write_cooldown(time.time(), {"outcome": "start_failed", "start_exit": start_code})
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
    if args.once:
        outcome = tick()
        log.info("once outcome: %s", outcome)
        return 0

    log.info(
        "silence watchdog started (threshold=%ds poll=%ds cooldown=%ds heartbeat=%ds)",
        SILENCE_THRESHOLD, POLL_INTERVAL, RESTART_COOLDOWN, HEARTBEAT_INTERVAL,
    )
    while True:
        try:
            tick()
        except Exception as exc:  # noqa: BLE001 — supervisor must not die on any cycle error
            log.error("watchdog cycle error: %s", exc)
        time.sleep(POLL_INTERVAL)


def cmd_status(args: argparse.Namespace) -> int:
    print(f"audit_log: {BRIDGE_AUDIT_LOG}")
    print(f"daemon_pid_file: {BRIDGE_DAEMON_PID_FILE}")
    print(f"heartbeat_interval_seconds: {HEARTBEAT_INTERVAL}")
    print(f"silence_threshold_seconds: {SILENCE_THRESHOLD}")
    print(f"poll_interval_seconds: {POLL_INTERVAL}")
    print(f"restart_cooldown_seconds: {RESTART_COOLDOWN}")
    last = find_last_daemon_tick(BRIDGE_AUDIT_LOG, TAIL_BYTES)
    if last is None:
        print("last_daemon_tick: (none in tail window)")
    else:
        print(f"last_daemon_tick: {last.raw_ts} (age={int(last.age_seconds)}s)")
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
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="bridge-watchdog-silence.py")
    sub = parser.add_subparsers(dest="command", required=True)

    run_p = sub.add_parser("run")
    run_p.add_argument("--once", action="store_true", help="run a single tick and exit")
    run_p.set_defaults(handler=cmd_run)

    status_p = sub.add_parser("status")
    status_p.set_defaults(handler=cmd_status)

    args = parser.parse_args()
    # Issue #591: refuse to run with a cross-home pid file before any state
    # read or audit peek so a leaked-env orphan terminates itself instead of
    # cross-home killing the live daemon.
    _validate_cross_home()
    return int(args.handler(args))


if __name__ == "__main__":
    sys.exit(main())
