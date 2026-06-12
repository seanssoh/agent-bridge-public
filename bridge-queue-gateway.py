#!/usr/bin/env python3
"""Queue RPC gateway for isolated static agents.

The legacy transport is file-backed and remains the default.  The socket
transport is opt-in via BRIDGE_GATEWAY_TRANSPORT=socket and is served by the
bridge daemon over a Unix domain SOCK_SEQPACKET socket.

Platform contract — socket transport is Linux-only and fail-closed:
  * Peer authentication relies on SO_PEERCRED, which is Linux-only.  macOS /
    BSD provide LOCAL_PEERCRED / getpeereid with different semantics; we do
    NOT attempt cross-platform peer auth here.  Both the listener and the
    socket-client refuse to start on non-Linux hosts so credential checks
    cannot silently pass.  Operators on non-Linux hosts must use the file
    transport (BRIDGE_GATEWAY_TRANSPORT=file, the default).
  * Socket transport is also a Linux-system-mode install: the runtime root
    (/run/agent-bridge by default) is owned by root, provisioned via
    tmpfiles.d, and managed by the bridge daemon.  Non-root operators
    running socket transport in live mode are not supported — verification
    will fail because the tmpfiles entry expects root ownership.
"""

from __future__ import annotations

import argparse
import atexit
import grp
import hashlib
import json
import os
import pwd
import secrets
import signal
import socket
import sqlite3
import stat
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


LIVE_GATEWAY_RUNTIME_ROOT = "/run/agent-bridge"
SOCKET_NAME = "queue-gateway.sock"
MAX_SOCKET_BYTES = 2 * 1024 * 1024
SOCKET_TIMEOUT_SECONDS = 5.0
SOCKET_ACL_REFRESH_SECONDS = 30.0
BRIDGE_SHARED_GROUP_DEFAULT = "ab-shared"
INLINE_OVERHEAD_BYTES = 64 * 1024
INLINE_BODY_CAP_BYTES = MAX_SOCKET_BYTES - INLINE_OVERHEAD_BYTES
SOCKET_LINUX_ONLY_MESSAGE = (
    "queue gateway socket transport requires Linux (SO_PEERCRED); "
    "use BRIDGE_GATEWAY_TRANSPORT=file on this platform"
)


# Public reason codes the gateway is willing to disclose to *any* peer.
# Detailed internal reason codes (e.g. task_not_found, done_not_owner) leak
# task existence / ownership across the isolation boundary; map them to one
# of these public codes before sending to the client. The detailed code is
# still recorded server-side via gateway_log() for operator triage.
#
# Anything not in this set is collapsed to internal_error for the client.
_PUBLIC_REASON_CODES: frozenset[str] = frozenset({
    "not_authorized",       # generic auth/ownership/visibility failure
    "task_unavailable",     # reserved for future generic existence failures (no current emitter)
    "unknown_option",       # argv parser rejection (already public-safe)
    "task_id_required",     # peer's own argv shape — discloses nothing new
    "invalid_argument",     # argparse / format failure
    "invalid_argv",         # peer's own argv was malformed
    "invalid_payload",      # peer's own JSON payload was malformed
    "oversize_payload",     # peer sent a too-large payload
    "duplicate_file_arg",   # peer's own argv had a duplicate flag
    "empty_argv",           # peer sent an empty argv
    "file_arg_denied",      # peer used a *_file flag (gateway never forwards)
    "subcmd_denied",        # generic subcommand denial (peer-known)
    "init_denied",          # subcmd-shaped denials of internal-only commands
    "cron-ready_denied",
    "daemon-step_denied",
    "note-nudge_denied",
    "events_denied",
    "unknown_peer",         # peer's own UID is not in the roster
    "internal_error",       # generic catch-all for unexpected
})


# Map detailed (leaky) reason codes to the public-safe code that the client
# should see. Codes already in _PUBLIC_REASON_CODES are passed through.
# Anything else falls back to internal_error.
_PUBLIC_REASON_MAP: dict[str, str] = {
    # task_not_found collapses to not_authorized (same as ownership/visibility
    # failures) so a peer cannot distinguish "task does not exist" from "task
    # exists but you cannot see it" — both leak task-id existence otherwise.
    "task_not_found": "not_authorized",
    "show_not_visible": "not_authorized",
    "done_not_owner": "not_authorized",
    "claim_not_assigned": "not_authorized",
    "cancel_not_owner": "not_authorized",
    "update_not_owner": "not_authorized",
    "handoff_not_owner": "not_authorized",
    # Rooms ACL (P1b): a cross-room / fail-closed create denial. Collapsed to
    # not_authorized so a peer cannot enumerate which agents share which rooms
    # by probing create targets — the detailed acl_* code is still logged
    # server-side via gateway_log() for operator triage.
    "acl_denied": "not_authorized",
    "acl_fail_closed": "not_authorized",
    "rooms_acl_unavailable": "internal_error",
    "exception": "internal_error",
}


def _public_reason_code(detailed_reason: str) -> str:
    """Map an internal reason code to the client-visible public code.

    Public codes pass through; known leaky codes are mapped via
    _PUBLIC_REASON_MAP; anything unrecognised falls back to internal_error
    so a future detailed reason cannot accidentally leak across the
    isolation boundary without an explicit allow-list update.
    """
    if detailed_reason in _PUBLIC_REASON_CODES:
        return detailed_reason
    return _PUBLIC_REASON_MAP.get(detailed_reason, "internal_error")


def _socket_transport_supported() -> bool:
    """Linux-only fail-closed gate for the socket transport.

    SO_PEERCRED is the only credential mechanism this gateway implements;
    it is Linux-specific.  Returning False on any other platform forces
    callers to either fall back to the file transport or fail with a
    recognizable error rather than silently bypass peer auth.
    """
    return sys.platform.startswith("linux") and hasattr(socket, "SO_PEERCRED")


def _load_rooms_common() -> Any:
    """Import bridge_rooms_common from this script's dir (lazy, optional).

    Returns the module, or None if it cannot be imported (a pre-P1a install
    or a stripped deployment). The rooms ACL gate degrades to a no-op pass
    when the module is unavailable — never failing a legitimate create just
    because the rooms control plane is absent.
    """
    import importlib.util

    here = Path(__file__).resolve().parent
    path = here / "bridge_rooms_common.py"
    if not path.exists():  # noqa: raw-pathlib-controller-only — gateway runs as the controller daemon; this probes a sibling SOURCE file, not an isolated-agent artifact
        return None
    try:
        spec = importlib.util.spec_from_file_location("bridge_rooms_common", str(path))
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:  # noqa: BLE001 - any import fault -> no-op (fail open to pre-P1b behavior)
        return None


# The value-consuming flags of `bridge-queue.py create` (each takes the NEXT
# token). Used by _create_target so a `--to` appearing INSIDE another flag's
# value (e.g. `--title "... --to fake"`) is never misread as the recipient.
# Keep in sync with the create subparser in bridge-queue.py. `--body-file` /
# `--note-file` are gated upstream by _has_file_arg and never reach here.
_CREATE_VALUE_FLAGS = frozenset({
    "--to", "--title", "--from", "--priority", "--format", "--body",
})


def _create_target(argv: list[str]) -> str:
    """Extract the `--to <agent>` recipient from a `create` argv (or '')."""
    skip = False
    for idx, token in enumerate(argv[1:], start=1):
        if skip:
            skip = False
            continue
        if token == "--to":
            return argv[idx + 1].strip() if idx + 1 < len(argv) else ""
        if token.startswith("--to="):
            return token.split("=", 1)[1].strip()
        flag_name = token.split("=", 1)[0]
        if token.startswith("--") and flag_name in _CREATE_VALUE_FLAGS and "=" not in token:
            # `--flag value` consumes the next token; `--flag=value` does not.
            skip = True
    return ""


def _rooms_acl_gate_create(home: str, peer_agent: str, argv: list[str]) -> tuple[bool, str]:
    """Apply the rooms ACL to an iso-v2 (gateway) `create`. Returns (ok, reason).

    `peer_agent` is the SO_PEERCRED OS-trusted actor (the gateway already
    rewrote --from to it), so the ACL decision uses an un-spoofable sender —
    the client-supplied --from/BRIDGE_AGENT_ID can never grant another agent's
    room membership. Degrades to an ALLOW pass when:
      - the rooms module is unavailable (pre-P1a / stripped install),
      - rooms_acl is off (default — true no-op),
      - no rooms are defined (back-compat),
      - the create is exempt (self-message / target-unroomed).
    A cross-room or fail-closed verdict returns (False, <acl reason>).
    """
    rooms = _load_rooms_common()
    if rooms is None:
        return True, "ok"
    # The gateway peer is ALWAYS an OS-enforced iso actor, so this is a HARD path:
    # read the mode STRICTLY. A genuinely ABSENT rooms.db -> off (back-compat). A
    # present-but-UNREADABLE/corrupt rooms.db must NOT degrade to 'off' (that
    # would silently drop a previously-enforced boundary — codex r1 BLOCKING);
    # it fails CLOSED here.
    try:
        mode = rooms.rooms_acl_mode_strict()
    except Exception:  # noqa: BLE001 - present-but-unreadable rooms.db under a hard actor
        return False, "acl_fail_closed"
    if mode != rooms.ACL_ENFORCE:
        return True, "ok"
    target = _create_target(argv)
    if not target:
        # No --to to gate (e.g. a malformed create); let the inner parser
        # reject it normally rather than inventing an ACL denial.
        return True, "ok"
    try:
        decision = rooms.acl_create_decision(
            mode=mode,
            # The gateway peer is an OS-enforced iso agent (SO_PEERCRED).
            regime=rooms.ACTOR_ISO_ENFORCED,
            actor=peer_agent,
            target=target,
            node="",
        )
    except Exception:  # noqa: BLE001 - decision fault under enforce -> fail closed
        return False, "rooms_acl_unavailable"
    if decision.outcome == "deny":
        return False, decision.reason
    return True, "ok"


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}.{secrets.token_hex(4)}")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    # L1-N (beta21) tail: chmod 0640 so the file-mode gateway's
    # request/response pair is readable by EITHER side. Without this,
    # the controller daemon writes responses at its own umask (typically
    # 077 → 0600 owned by `sean`) into the per-agent responses/ dir,
    # and the iso UID's poll loop can never read them — `agb task create`
    # from iso UID would PermissionError on the response file even
    # though L1-N fixed bridge_load_roster, the request was queued
    # successfully, and the daemon processed it. The setgid bit on
    # the parent dir already ensures the file inherits the
    # ab-agent-<X> group, so 0640 (owner+group rw, owner+group r)
    # gives BOTH the controller and the iso UID read access without
    # widening the surface beyond the per-agent group. Same code path
    # writes request files (iso UID → controller) and response files
    # (controller → iso UID); both directions benefit.
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit(f"invalid gateway payload: {path}")
    return payload


def bridge_home(default: str | None = None) -> str:
    return default or os.environ.get("BRIDGE_HOME") or str(Path.home() / ".agent-bridge")


def bridge_runtime_id(home: str) -> str:
    canonical = os.path.realpath(os.path.expanduser(home))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:12]


def gateway_runtime_root() -> Path:
    # This intentionally uses a queue-gateway-specific variable.  BRIDGE_RUNTIME_ROOT
    # already names Agent Bridge's private runtime asset tree.
    raw = os.environ.get("BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT", LIVE_GATEWAY_RUNTIME_ROOT)
    return Path(raw).expanduser()


def gateway_instance_dir(home: str) -> Path:
    return gateway_runtime_root() / bridge_runtime_id(home)


def gateway_socket_path(home: str) -> Path:
    return gateway_instance_dir(home) / SOCKET_NAME


def task_db_path(home: str) -> Path:
    state_dir = os.environ.get("BRIDGE_STATE_DIR", str(Path(home).expanduser() / "state"))
    return Path(os.environ.get("BRIDGE_TASK_DB", str(Path(state_dir) / "tasks.db")))


# Client-side gateway contract (#1837 keystone / #1834). The file transport's
# response round-trip is best-effort: the daemon (cmd_serve_once) polls each
# agent's requests/ dir every ~5s, renames a request to <id>.working.json BEFORE
# processing it, and ALWAYS writes a responses/<id>.json carrying the queue
# child's REAL exit code (including the idempotent "task already done" -> 0).
#
# The bug (#1837): under burst load the client's response READ timed out long
# after the daemon committed the SQLite write, and cmd_client raised "queue
# gateway timed out" + exit 1. Autonomous callers treated the committed write as
# a failure and RETRIED, writing more request files and compounding the
# contention into a self-reinforcing thrash. #1834 is the same surface — a
# transient 1-6x per-call timeout against a live daemon with no built-in retry.
#
# CRITICAL boundary fact: cmd_client runs ONLY as the isolated-agent UID
# (bridge_queue_gateway_proxy_agent gates on linux-user isolation), and that env
# sets BRIDGE_TASK_DB=/dev/null + BRIDGE_GATEWAY_PROXY=1 so the agent CANNOT touch
# the controller task DB directly (the entire reason the gateway exists; see
# lib/bridge-agents.sh "BRIDGE_TASK_DB is sentineled" / #287 / #294). So the
# client has exactly ONE authoritative signal for whether a write committed: the
# daemon's response file. The fix is therefore NOT to guess the outcome from the
# DB (impossible here) but to WAIT LONG ENOUGH to read the real response:
#
#   * #1834 — a bounded read-side retry with backoff before declaring a timeout,
#     so a transient flap resolves in-process from the daemon's own (slightly
#     delayed) response instead of forcing the caller to loop.
#   * #1837 — the response carries the queue child's true exit code, so once the
#     bounded wait reads it the client returns that real code (idempotent
#     already-done -> 0 included). We NEVER fabricate a success the daemon did
#     not actually report; the keystone is "read the real response, don't give
#     up early," not "assume the write landed."
#
# The retry only re-polls for the response — it never re-queues a fresh write
# (that re-queue is the very thrash we are fixing), and the request file the
# daemon may still be draining as <id>.working.json is untouched by the retry.


def gateway_daemon_liveness(home: str) -> str:
    """Tri-state daemon liveness as seen from the calling (possibly iso) UID.

    Returns one of:
      * ``"up"``      — the daemon pid file is readable AND the pid is alive.
      * ``"down"``    — the daemon pid file is readable AND the pid is dead/absent.
      * ``"unknown"`` — the daemon pid file cannot be read FROM THIS CONTEXT (the
                        iso boundary blocks the controller's pid file). The daemon
                        may well be alive; the caller MUST NOT render this as
                        "down". This is the #1837 false-"daemon down" guard.

    The pid-file path mirrors the canonical resolution the rest of the bridge
    uses (bridge-lib.sh / bridge-daemon-control.sh): ``BRIDGE_DAEMON_PID_FILE``
    when set (relocated/custom installs export it into the iso agent env too),
    else ``<BRIDGE_STATE_DIR>/daemon.pid``. Hardcoding the state-dir path would
    false-report "unknown" on a custom-pid-file install even with a live daemon.

    A3 (#1833 status presentation) consumes this primitive instead of inferring
    liveness from a raw pid read that false-positives "down" across the iso
    boundary. This function NEVER mutates anything and never raises.
    """
    pid_file = os.environ.get("BRIDGE_DAEMON_PID_FILE", "").strip()
    if pid_file:
        pid_path = Path(pid_file).expanduser()
    else:
        state_dir = os.environ.get("BRIDGE_STATE_DIR", str(Path(home).expanduser() / "state"))
        pid_path = Path(state_dir) / "daemon.pid"
    try:
        raw = pid_path.read_text(encoding="utf-8").strip()
    except (PermissionError, OSError):
        # PermissionError: iso boundary blocked the read → genuinely unknown.
        # FileNotFoundError (an OSError subclass): no pid file. We still report
        # "unknown" rather than "down" because a fresh/racing daemon may not have
        # published its pid yet and the cost of a false "down" (drives the wrong
        # operator/agent response) is higher than a conservative "unknown".
        return "unknown"
    if not raw:
        return "unknown"
    try:
        pid = int(raw.split()[0])
    except (ValueError, IndexError):
        return "unknown"
    try:
        os.kill(pid, 0)
    except PermissionError:
        # The process exists but is owned by another UID we may not signal —
        # existence is what we need. Still cmdline-verify below before "up".
        pass
    except (ProcessLookupError, OSError):
        return "down"
    # A live PID alone is not proof: a stale pid file can point at a RECYCLED
    # pid now owned by some unrelated process, which would false-report "up".
    # Verify the cmdline looks like the bridge daemon (mirrors the shell
    # resolver's guard at lib/bridge-state.sh). When the cmdline is unreadable
    # (iso boundary / another UID), we cannot DISPROVE it, so we trust the pid —
    # consistent with the conservative "never false-down" contract.
    daemon_script = str(Path(home).expanduser() / "bridge-daemon.sh")
    if _pid_cmdline_disproves_daemon(pid, daemon_script):
        return "down"
    return "up"


# Basenames of the shell interpreters that legitimately launch the daemon as
# `<shell> <home>/bridge-daemon.sh run` (bridge-daemon.sh dispatches via
# `bash bridge-daemon.sh run`; the live install proof shows argv[0] is the
# bash binary). Keeps the position-anchor below tolerant of any bash path.
_DAEMON_SHELL_LAUNCHERS = frozenset({"bash", "sh", "dash", "zsh", "ksh"})


def _pid_cmdline_disproves_daemon(pid: int, daemon_script: str) -> bool:
    """True only when we can READ the pid's argv AND it is clearly NOT the
    bridge daemon (a recycled-pid false positive). Unreadable argv -> False
    (cannot disprove; trust the pid), matching the shell resolver's guard.

    ``daemon_script`` is the install's canonical ``<home>/bridge-daemon.sh``."""
    argv = _read_pid_argv(pid)
    if not argv:
        return False
    return not _argv_is_daemon_run(argv, daemon_script)


def _argv_is_daemon_run(argv: list[str], daemon_script: str) -> bool:
    """POSITION-ANCHORED proof that ``argv`` is the running bridge daemon.

    The real daemon runs as ``<shell> <home>/bridge-daemon.sh run`` (see
    bridge-daemon.sh's `bash bridge-daemon.sh run` dispatch; the live-install
    pidfile target's argv is exactly ``<bash> <home>/bridge-daemon.sh run``), or
    — if exec'd directly via its shebang — ``<home>/bridge-daemon.sh run``. So
    the canonical script must sit in the *executed-script position*:
      * ``argv[0]`` == <home>/bridge-daemon.sh, ``argv[1]`` == "run"   (direct), OR
      * ``argv[0]`` is a shell, ``argv[1]`` == <home>/bridge-daemon.sh,
        ``argv[2]`` == "run"                                           (wrapped).

    Why position, not a token-anywhere scan: a path-anchored *token-anywhere*
    match (basename==bridge-daemon.sh AND realpath==<home> AND next=="run",
    scanned over every argv element) still false-reported "up" for a LIVE
    NON-daemon process that merely carries the genuine path + "run" as ordinary
    trailing DATA, e.g. ``python3 -c '<code>' <home>/bridge-daemon.sh run`` (the
    path is an argument to ``python -c``, not the script being executed). codex
    #12972 and patch-dev #12973 reproduced exactly that on ca17c4f5. Anchoring on
    the script POSITION (argv[0], or argv[1] behind a shell) — not its mere
    presence — closes that class.

    Residual (accepted): a *deliberate* argv[0] spoof (``exec -a
    <home>/bridge-daemon.sh someprog run``) would still pass. That is out of
    scope for a liveness *status* heuristic — the pidfile is the primary signal,
    and this cmdline check only DISPROVES *coincidental* recycled-pid reuse, not
    an adversary who has already arranged to forge the daemon's argv[0]."""
    expected = os.path.realpath(daemon_script)

    def _is_canonical_script(tok: str) -> bool:
        return (
            os.path.basename(tok) == "bridge-daemon.sh"
            and os.path.realpath(tok) == expected
        )

    # Direct/shebang exec: `<home>/bridge-daemon.sh run`
    if len(argv) >= 2 and _is_canonical_script(argv[0]) and argv[1] == "run":
        return True
    # Shell-wrapped: `<shell> <home>/bridge-daemon.sh run`
    if (
        len(argv) >= 3
        and os.path.basename(argv[0]) in _DAEMON_SHELL_LAUNCHERS
        and _is_canonical_script(argv[1])
        and argv[2] == "run"
    ):
        return True
    return False


def _read_pid_argv(pid: int) -> list[str] | None:
    """Best-effort process argv as a TOKEN LIST. Linux /proc first (true
    NUL-delimited argv — preserves elements that contain spaces, e.g. a
    ``python3 -c '<code with spaces>'`` payload, so the position-anchor cannot
    be fooled by argv-element splitting); then ``ps -p <pid> -o args=``
    whitespace-split (lossy — shell quoting is not recoverable from ps, but the
    daemon's real argv ``<shell> <home>/bridge-daemon.sh run`` is exactly three
    space-free tokens, so its position is unambiguous either way). None when
    neither source is available/readable."""
    proc_cmdline = Path(f"/proc/{pid}/cmdline")
    try:
        raw = proc_cmdline.read_bytes()  # noqa: raw-pathlib-controller-only — world-readable /proc entry of the (controller) daemon pid, not an isolated-agent artifact
        if raw:
            argv = [p.decode("utf-8", "replace") for p in raw.split(b"\x00") if p]
            if argv:
                return argv
    except OSError:
        pass
    try:
        proc = subprocess.run(
            ["ps", "-p", str(pid), "-o", "args="],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            out = proc.stdout.strip()
            if out:
                return out.split()
    except (OSError, ValueError):
        pass
    return None


def agent_root(root: Path, agent: str) -> Path:
    return root / agent


def request_dir(root: Path, agent: str) -> Path:
    return agent_root(root, agent) / "requests"


def response_dir(root: Path, agent: str) -> Path:
    return agent_root(root, agent) / "responses"


def _emit_gateway_response(payload: dict[str, Any]) -> int:
    """Write a gateway response payload's stdout/stderr through and return exit."""
    stdout = str(payload.get("stdout", ""))
    stderr = str(payload.get("stderr", ""))
    if stdout:
        sys.stdout.write(stdout)
    if stderr:
        sys.stderr.write(stderr)
    return int(payload.get("exit_code", 1))


def _poll_for_response(response_path: Path, deadline: float, poll: float) -> dict[str, Any] | None:
    """Poll for the daemon's response file until `deadline`. None on timeout."""
    while time.monotonic() < deadline:
        if response_path.exists():  # noqa: raw-pathlib-controller-only — the gateway client polls its OWN per-agent response file, not an isolated-agent artifact
            payload = load_json(response_path)
            try:
                response_path.unlink()  # noqa: raw-pathlib-controller-only — consuming the client's own response file (unchanged from the original poll loop)
            except OSError:
                pass
            return payload
        time.sleep(poll)
    # One final non-sleeping check closes the race where the daemon wrote the
    # response between the last poll and the deadline expiring.
    if response_path.exists():  # noqa: raw-pathlib-controller-only — final race check on the client's own response file
        payload = load_json(response_path)
        try:
            response_path.unlink()  # noqa: raw-pathlib-controller-only — consuming the client's own response file
        except OSError:
            pass
        return payload
    return None


def _env_float(name: str, default: float, minimum: float = 0.0) -> float:
    """Parse a float tunable from env, clamped to `minimum`, never raising.

    A MALFORMED value must not crash the gateway client: the parse happens before
    the request is enqueued, and a traceback there would leave a queued request
    the daemon may still execute while the caller retries -> duplicate mutations
    (the very thrash #1837 guards against). Bad input falls back to the default.
    """
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return max(minimum, default)
    try:
        return max(minimum, float(raw))
    except ValueError:
        return max(minimum, default)


def _env_int(name: str, default: int, minimum: int = 0) -> int:
    """Integer counterpart of _env_float — clamped, never raising. See _env_float."""
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return max(minimum, default)
    try:
        return max(minimum, int(raw))
    except ValueError:
        return max(minimum, default)


def cmd_client(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser()
    req_dir = request_dir(root, args.agent)
    resp_dir = response_dir(root, args.agent)
    req_dir.mkdir(parents=True, exist_ok=True)
    resp_dir.mkdir(parents=True, exist_ok=True)

    # Parse ALL tunables BEFORE enqueuing the request. A malformed --poll/--timeout
    # or retry env var must fail (or fall back) here, never after
    # atomic_write_json() has already queued a request the daemon may execute —
    # which would strand the request + traceback the client and let a caller retry
    # into a duplicate mutation (#1837 codex r5).
    poll = max(0.05, float(args.poll))
    base_timeout = max(1.0, float(args.timeout))
    retries = _env_int("BRIDGE_QUEUE_GATEWAY_READ_RETRIES", 3, minimum=0)
    backoff = _env_float("BRIDGE_QUEUE_GATEWAY_READ_BACKOFF_SECONDS", 0.5, minimum=0.0)

    request_id = f"{int(time.time() * 1000)}-{os.getpid()}-{secrets.token_hex(6)}"
    request_path = req_dir / f"{request_id}.request.json"
    response_path = resp_dir / f"{request_id}.json"
    # #1792: forward the cron dispatch run id as ATTRIBUTION METADATA only.
    # In the gateway path the queue child runs in the SERVER process, which
    # does not inherit the cron child's BRIDGE_CRON_RUN_ID, so without this the
    # origin stamp would be NULL for iso cron children. This is strictly
    # weaker than the already-client-asserted `--from` (origin never gates a
    # create); the server injects it into the child env but NEVER lets it
    # influence the trusted-actor / ACL / argv-rewrite decision.
    request_payload: dict[str, Any] = {
        "id": request_id,
        "agent": args.agent,
        "argv": list(args.argv),
        "cwd": os.getcwd(),
        "created_at": now_iso(),
    }
    cron_run_id = os.environ.get("BRIDGE_CRON_RUN_ID", "").strip()
    if cron_run_id:
        request_payload["cron_run_id"] = cron_run_id
    atomic_write_json(request_path, request_payload)

    # #1834 / #1837: bounded read-side retry. The daemon always writes a response
    # carrying the queue child's REAL exit code; under burst load it just arrives
    # late. Most iso-boundary timeouts are a 1–6× transient flap against a LIVE
    # daemon, so before declaring a read timeout we re-poll a few extra windows
    # with growing backoff (tunables parsed above, before the request was
    # enqueued). This waits LONGER for the authoritative response — it does NOT
    # re-queue a fresh write (that re-queue is exactly the thrash #1837
    # describes), and the request the daemon may still be draining as
    # <id>.working.json is untouched.
    deadline = time.monotonic() + base_timeout
    payload = _poll_for_response(response_path, deadline, poll)
    attempt = 0
    while payload is None and attempt < retries:
        # Growing backoff window (0.5s, 1.0s, 1.5s, … by default) for each extra
        # re-poll; the daemon ticks the gateway every ~5s so a couple of these
        # windows comfortably span a single missed poll.
        attempt += 1
        window = backoff * attempt
        if window <= 0:
            break
        payload = _poll_for_response(response_path, time.monotonic() + window, poll)

    if payload is not None:
        # The daemon's response is the authoritative outcome — return its REAL
        # exit code (idempotent "already done" -> 0 included). #1837 is fixed by
        # reading this real response instead of giving up before it lands; we
        # never fabricate a success the daemon did not report.
        try:
            request_path.unlink()  # noqa: raw-pathlib-controller-only — the client removes its OWN request file after a successful round-trip (unchanged contract)
        except OSError:
            pass
        return _emit_gateway_response(payload)

    # The bounded retry exhausted without a response. The client (an iso UID with
    # BRIDGE_TASK_DB=/dev/null) has no way to confirm the outcome other than the
    # response file, so we surface the honest timeout — never a fabricated
    # success. Remove the now-stale <id>.request.json so the next CLI call does
    # not pile a duplicate request on top (the thrash we are fixing); if the
    # daemon already renamed it to <id>.working.json this unlink is a no-op and
    # the daemon still drains that working copy on a later tick.
    try:
        request_path.unlink()  # noqa: raw-pathlib-controller-only — the client removes its OWN now-stale request file on a genuine timeout (matches the original behaviour)
    except OSError:
        pass
    raise SystemExit("queue gateway timed out waiting for daemon")


def iter_requests(root: Path) -> list[Path]:
    files = list(root.glob("*/requests/*.request.json"))
    files.extend(root.glob("*/requests/*.working.json"))

    def sort_key(item: Path) -> tuple[float, str]:
        try:
            mtime = item.stat().st_mtime
        except OSError:
            mtime = 0.0
        return (mtime, item.name)

    files.sort(key=sort_key)
    return files


def run_queue(
    queue_script: Path,
    argv: list[str],
    cwd: str | None,
    trusted_actor: str | None = None,
    cron_run_id: str | None = None,
) -> dict[str, Any]:
    child_env = os.environ.copy()
    child_env["BRIDGE_QUEUE_GATEWAY_SERVER"] = "1"
    child_env.pop("BRIDGE_GATEWAY_PROXY", None)
    # #1792: attribution-only. The queue child's resolve_origin() derives the
    # task origin from this env, so the child must see ONLY the forwarded
    # signal — never the gateway SERVER's own inherited identity. Scrub the
    # server's session-id vars (a gateway launched from a Claude session would
    # otherwise misattribute EVERY gateway create as session:<server-session>),
    # then set BRIDGE_CRON_RUN_ID from the forwarded value or clear it. A client
    # that forwarded a run id gets origin=cron:<id>; one that did not gets the
    # legacy NULL origin. This feeds cmd_create's resolve_origin and NOTHING
    # else — never the trusted actor.
    for _session_key in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "ANTHROPIC_SESSION_ID"):
        child_env.pop(_session_key, None)
    # #1792: forward the client's claimed cron run id into the child env as
    # PROPOSED attribution only. The re-executed bridge-queue.py does NOT trust
    # it blind — resolve_origin() proves it against the cron runtime's ground
    # truth (runs/<id>/status.json state=running) before stamping cron:<id>, so
    # a non-cron client that forwarded its own env value cannot mint a cron
    # origin (#1792 P1). We always (re)set or clear so a stale value from the
    # gateway process env cannot leak across requests.
    cron_run_id = (cron_run_id or "").strip()
    if cron_run_id:
        child_env["BRIDGE_CRON_RUN_ID"] = cron_run_id
    else:
        child_env.pop("BRIDGE_CRON_RUN_ID", None)
    # Rooms ACL (P1b): pass the OS-derived trusted actor to the queue child as an
    # env var the CLIENT cannot set (this is the gateway-server's own child env).
    # bridge-queue.py:cmd_create uses BRIDGE_QUEUE_GATEWAY_ACTOR as the ISO-
    # enforced sender, NEVER the client --from. We always (re)set it so a stale
    # value inherited from the gateway process env cannot leak across requests:
    # a real authenticated actor is set, an unauthenticated one is cleared.
    if trusted_actor:
        child_env["BRIDGE_QUEUE_GATEWAY_ACTOR"] = trusted_actor
    else:
        child_env.pop("BRIDGE_QUEUE_GATEWAY_ACTOR", None)

    proc = subprocess.run(
        [sys.executable, str(queue_script), *argv],
        cwd=cwd,
        capture_output=True,
        text=True,
        env=child_env,
        check=False,
    )
    return {
        "exit_code": int(proc.returncode),
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "processed_at": now_iso(),
    }


def _file_request_owner_agent(path: Path) -> str:
    """Map the request file's OWNER UID -> agent for the file transport (P1b).

    The file transport's OS boundary is request-file OWNERSHIP: an iso agent can
    only create request files it owns under its own per-agent requests/ dir
    (mode 2770, owned by the iso UID). So the trusted actor is the file OWNER's
    uid mapped through the roster uid->agent table — NOT the client-supplied
    `agent`/`--from` field in the JSON (which an iso agent could forge to a room
    peer). Returns '' when the owner uid maps to no iso agent (controller-owned
    request, or roster probe unavailable) — the caller then withholds the
    trusted-actor signal so cmd_create fails closed under enforce rather than
    trusting a client id.
    """
    try:
        owner_uid = path.stat().st_uid  # noqa: raw-pathlib-controller-only — controller-side gateway server reads the request-file owner uid (the file transport's OS boundary)
    except OSError:
        return ""
    script_dir = Path(__file__).resolve().parent
    try:
        peer_map = _peer_map_from_roster(script_dir)
    except SystemExit:
        return ""
    return peer_map.get(owner_uid, "")


def handle_request(path: Path, queue_script: Path) -> int:
    try:
        request = load_json(path)
    except Exception as exc:
        response = {
            "id": path.name.split(".", 1)[0],
            "exit_code": 1,
            "stdout": "",
            "stderr": f"invalid queue gateway request: {exc}\n",
            "processed_at": now_iso(),
        }
        atomic_write_json(path.parent.parent / "responses" / f"{response['id']}.json", response)
        path.unlink(missing_ok=True)
        return 1

    agent = str(request.get("agent", "")).strip()
    argv = request.get("argv", [])
    cwd = str(request.get("cwd", "")).strip() or None
    if not agent or not isinstance(argv, list) or not all(isinstance(item, str) for item in argv):
        response = {
            "id": str(request.get("id", path.name.split(".", 1)[0])),
            "exit_code": 1,
            "stdout": "",
            "stderr": "invalid queue gateway request payload\n",
            "processed_at": now_iso(),
        }
        atomic_write_json(path.parent.parent / "responses" / f"{response['id']}.json", response)
        path.unlink(missing_ok=True)
        return 1

    response = {"id": str(request.get("id", path.name.split(".", 1)[0]))}
    # Rooms ACL (P1b) for the FILE transport: the trusted actor is the request
    # file's OWNER uid (the file transport's OS boundary), NOT the client `agent`
    # field. For a `create`, run the same authorize_and_rewrite the socket path
    # uses so --from is rewritten to the owner-derived actor AND the rooms ACL
    # gate fires; then hand that owner actor to the queue child as the trusted
    # actor. When the owner maps to no iso agent (controller-owned request or no
    # roster probe), we DO authorize as the controller-side `agent` for back-
    # compat with the existing file transport, but withhold the trusted-actor
    # signal so cmd_create's own resolve_os_actor / fail-closed contract applies.
    trusted_actor: str | None = None
    run_argv = argv
    if argv and argv[0] == "create":
        owner_agent = _file_request_owner_agent(path)
        if owner_agent:
            ok, reason, rewritten = authorize_and_rewrite(bridge_home(), owner_agent, argv)
            if not ok:
                response.update({
                    "exit_code": 2,
                    "stdout": "",
                    "stderr": "queue gateway denied\n",
                    "decision": "deny",
                    "reason_code": _public_reason_code(reason),
                    "processed_at": now_iso(),
                })
                atomic_write_json(path.parent.parent / "responses" / f"{response['id']}.json", response)
                path.unlink(missing_ok=True)  # noqa: raw-pathlib-controller-only — controller-side gateway server consumes its own request file (mirrors the existing unlink below)
                return 0
            run_argv = rewritten
            trusted_actor = owner_agent
    request_cron_run_id = str(request.get("cron_run_id", "") or "").strip()
    response.update(
        run_queue(queue_script, run_argv, cwd, trusted_actor=trusted_actor, cron_run_id=request_cron_run_id)
    )
    atomic_write_json(path.parent.parent / "responses" / f"{response['id']}.json", response)
    path.unlink(missing_ok=True)
    return 0


def cmd_serve_once(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser()
    queue_script = Path(args.queue_script).expanduser()
    processed = 0
    for candidate in iter_requests(root):
        if args.max_requests and processed >= args.max_requests:
            break
        if candidate.name.endswith(".working.json"):
            working = candidate
        else:
            working = candidate.with_name(candidate.name.replace(".request.json", ".working.json"))
        try:
            if candidate != working:
                os.replace(candidate, working)
        except OSError:
            continue
        handle_request(working, queue_script)
        processed += 1

    print(processed)
    return 0


def _user_name(uid: int) -> str:
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def _group_name(gid: int) -> str:
    try:
        return grp.getgrgid(gid).gr_name
    except KeyError:
        return str(gid)


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def verify_runtime_layout(home: str) -> tuple[bool, str]:
    root = gateway_runtime_root()
    inst = gateway_instance_dir(home)
    current_uid = os.getuid()
    parent_uid = 0 if str(root) == LIVE_GATEWAY_RUNTIME_ROOT else current_uid

    for label, path in (("parent", root), ("instance", inst)):
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            return False, f"{label}_missing"
        if stat.S_ISLNK(st.st_mode):
            return False, f"{label}_symlink"
        if not stat.S_ISDIR(st.st_mode):
            return False, f"{label}_not_dir"

    parent = root.stat()
    if parent.st_uid != parent_uid or stat.S_IMODE(parent.st_mode) != 0o755:
        return False, "parent_owner_mode"

    child = inst.stat()
    if child.st_uid != current_uid:
        return False, "instance_owner_mode"
    shared_grp = _shared_group()
    is_live = str(gateway_runtime_root()) == LIVE_GATEWAY_RUNTIME_ROOT
    if shared_grp is not None:
        if stat.S_IMODE(child.st_mode) != 0o2770 or child.st_gid != shared_grp.gr_gid:
            return False, "instance_owner_mode"
    elif is_live:
        return False, "instance_shared_group_missing"
    else:
        if stat.S_IMODE(child.st_mode) != 0o711:
            return False, "instance_owner_mode"

    return True, "ok"


def tmpfiles_dir() -> Path:
    return Path(os.environ.get("BRIDGE_TMPFILES_DIR", "/etc/tmpfiles.d")).expanduser()


def _conf_paths(home: str) -> tuple[Path, Path]:
    bridge_id = bridge_runtime_id(home)
    root_conf = tmpfiles_dir() / "agent-bridge.conf"
    inst_conf = tmpfiles_dir() / f"agent-bridge-{bridge_id}.conf"
    return root_conf, inst_conf


def _conf_contents(home: str) -> tuple[str, str]:
    """Render the tmpfiles.d config pair for the runtime root + instance.

    Live mode (gateway_runtime_root() == /run/agent-bridge) is the
    supported deployment: the parent is owned by root, provisioned by
    systemd-tmpfiles, and the bridge daemon runs the listener under the
    controller uid. Verification (verify_runtime_layout) requires
    parent_uid == 0 in this mode, so the tmpfiles emit must match.

    Smoke / dev mode (BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT pointed at a
    user-writable path) is the test-only path. systemd-tmpfiles is NOT
    invoked here; _apply_tmpfiles_shim chmod/chown the dirs as the
    current uid. Emit a config that matches what the shim actually does
    so the file is internally consistent — this keeps the contradiction
    (finding 6, r2 review) from re-surfacing if the smoke fixture is
    ever copied to a real /etc/tmpfiles.d.
    """
    root = gateway_runtime_root()
    inst = gateway_instance_dir(home)
    user = _user_name(os.getuid())
    group = _group_name(os.getgid())
    if str(root) == LIVE_GATEWAY_RUNTIME_ROOT:
        # Live mode: parent must be root-owned (verification enforces this).
        # Non-root operators choosing socket transport in live mode is
        # explicitly unsupported; the verify path will fail loudly.
        parent_user = "root"
        parent_group = "root"
    else:
        # Smoke / dev mode: the shim cannot chown to root unless euid==0,
        # so the tmpfiles content tracks the actual on-disk state.
        parent_user = user
        parent_group = group
    parent = f"d {root} 0755 {parent_user} {parent_group} -\n"
    shared_grp = _shared_group()
    if shared_grp is not None:
        child = f"d {inst} 2770 {user} {shared_grp.gr_name} -\n"
    else:
        child = f"d {inst} 0711 {user} {group} -\n"
    return parent, child


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _apply_tmpfiles_shim(home: str) -> None:
    root = gateway_runtime_root()
    inst = gateway_instance_dir(home)
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o755)
    # In non-live smoke roots, root-owned tmpfiles entries are mapped to the
    # controller uid.  Live mode still attempts the real root ownership.
    if str(root) == LIVE_GATEWAY_RUNTIME_ROOT and os.geteuid() == 0:
        os.chown(root, 0, 0)
    inst.mkdir(parents=True, exist_ok=True)
    shared_grp = _shared_group()
    if shared_grp is not None:
        os.chown(inst, os.getuid(), shared_grp.gr_gid)
        os.chmod(inst, 0o2770)
    else:
        os.chown(inst, os.getuid(), os.getgid())
        os.chmod(inst, 0o711)


def _sudo_available() -> bool:
    try:
        return subprocess.run(["sudo", "-n", "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except FileNotFoundError:
        return False


def _sudo_install_tmpfiles(home: str) -> bool:
    root_conf, inst_conf = _conf_paths(home)
    parent_text, child_text = _conf_contents(home)
    tmp_root = Path(os.environ.get("TMPDIR", "/tmp"))
    parent_tmp = tmp_root / f"agent-bridge-parent.{os.getpid()}.{secrets.token_hex(4)}.conf"
    child_tmp = tmp_root / f"agent-bridge-inst.{os.getpid()}.{secrets.token_hex(4)}.conf"
    parent_tmp.write_text(parent_text, encoding="utf-8")
    child_tmp.write_text(child_text, encoding="utf-8")
    try:
        for src, dst in ((parent_tmp, root_conf), (child_tmp, inst_conf)):
            proc = subprocess.run(
                ["sudo", "install", "-m", "0644", str(src), str(dst)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if proc.returncode != 0:
                return False
        proc = subprocess.run(
            ["sudo", "systemd-tmpfiles", "--create", str(root_conf), str(inst_conf)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return proc.returncode == 0
    finally:
        parent_tmp.unlink(missing_ok=True)
        child_tmp.unlink(missing_ok=True)


def ensure_runtime_layout(home: str, strict: bool) -> bool:
    ok, _reason = verify_runtime_layout(home)
    if ok:
        return True

    root_conf, inst_conf = _conf_paths(home)
    parent_text, child_text = _conf_contents(home)
    driver = os.environ.get("BRIDGE_TMPFILES_DRIVER", "systemd-tmpfiles").strip().lower()

    if driver == "shim":
        _write_text(root_conf, parent_text)
        _write_text(inst_conf, child_text)
        _apply_tmpfiles_shim(home)
    elif _sudo_available():
        if not _sudo_install_tmpfiles(home):
            return False
    else:
        # The remediation must match what verify_runtime_layout() now requires
        # for the instance dir, which depends on whether the shared group is
        # present and whether this is a live runtime root:
        #   - shared group present  -> 2770, group=<shared group>
        #   - absent + live         -> no valid layout; the group itself must
        #                              be created first (the old 0711 layout
        #                              can never pass the live verifier)
        #   - absent + non-live     -> 0711 owner-only (smoke/dev fallback)
        root = gateway_runtime_root()
        inst = gateway_instance_dir(home)
        shared_grp = _shared_group()
        if shared_grp is not None:
            print(
                "queue gateway runtime setup requires root once; run: "
                f"sudo install -d -m 0755 -o root -g root {root} && "
                f"sudo install -d -m 2770 -o {_user_name(os.getuid())} "
                f"-g {shared_grp.gr_name} {inst}",
                file=sys.stderr,
            )
        elif str(root) == LIVE_GATEWAY_RUNTIME_ROOT:
            name = os.environ.get(
                "BRIDGE_SHARED_GROUP", BRIDGE_SHARED_GROUP_DEFAULT
            ).strip()
            print(
                f"queue gateway runtime setup requires the '{name}' group "
                "(override via BRIDGE_SHARED_GROUP). Create the group, add the "
                "controller user and every isolated agent user to it, then "
                "restart the daemon. The pre-ab-shared owner-only layout is no "
                "longer accepted on a live runtime root.",
                file=sys.stderr,
            )
        else:
            print(
                "queue gateway runtime setup requires root once; run: "
                f"sudo install -d -m 0755 -o root -g root {root} && "
                f"sudo install -d -m 0711 -o {_user_name(os.getuid())} "
                f"-g {_group_name(os.getgid())} {inst}",
                file=sys.stderr,
            )
        return not strict

    ok, reason = verify_runtime_layout(home)
    if not ok:
        print(f"queue gateway runtime layout still invalid: {reason}", file=sys.stderr)
    return ok


def cmd_print_runtime_id(args: argparse.Namespace) -> int:
    print(bridge_runtime_id(bridge_home(args.bridge_home)))
    return 0


def cmd_daemon_liveness(args: argparse.Namespace) -> int:
    """Expose the tri-state daemon-down primitive (`up`/`down`/`unknown`).

    A3 (#1833 status presentation) invokes this so an iso UID that cannot read
    the controller's state/daemon.pid reports `unknown` instead of a false
    `down`. Always exit 0 — the liveness verdict is the payload, not the exit
    code (callers parse stdout / the JSON `liveness` field).
    """
    home = bridge_home(args.bridge_home)
    liveness = gateway_daemon_liveness(home)
    if args.format == "json":
        print(json.dumps({"liveness": liveness}, ensure_ascii=True))
    else:
        print(liveness)
    return 0


def cmd_verify_runtime(args: argparse.Namespace) -> int:
    ok, reason = verify_runtime_layout(bridge_home(args.bridge_home))
    if args.format == "json":
        print(json.dumps({"ok": ok, "reason": reason, "socket": str(gateway_socket_path(bridge_home(args.bridge_home)))}, ensure_ascii=True))
    elif not ok:
        print(reason, file=sys.stderr)
    return 0 if ok else 1


def cmd_ensure_runtime(args: argparse.Namespace) -> int:
    ok = ensure_runtime_layout(bridge_home(args.bridge_home), strict=bool(args.strict))
    return 0 if ok else 1


def _send_json(conn: socket.socket, payload: dict[str, Any]) -> None:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    if len(data) > MAX_SOCKET_BYTES:
        data = json.dumps(
            {"id": payload.get("id", ""), "exit_code": 1, "stdout": "", "stderr": "queue gateway response too large\n"},
            ensure_ascii=False,
        ).encode("utf-8")
    conn.sendall(data)


def _safe_send_json(conn: socket.socket, payload: dict[str, Any]) -> None:
    """Send a JSON response, swallowing peer-disconnect errors.

    Peers can vanish between accept() and the response (Ctrl-C, crash,
    request timeout, partial-frame followed by close). _send_json() will
    raise OSError / BrokenPipeError / ConnectionResetError in that case,
    and the listener used to bubble it up — re-entering an error path
    that itself called _send_json() would compound the failure and could
    kill the accept loop. Treat any send failure as terminal-for-this-
    peer only, log it once, and keep serving.
    """
    try:
        _send_json(conn, payload)
    except OSError as exc:
        request_id = str(payload.get("id") or "-")
        try:
            print(
                f"queue_gateway send_failed peer_gone={type(exc).__name__} "
                f"request_id={request_id}",
                file=sys.stderr,
                flush=True,
            )
        except OSError:
            pass


class _ProbeClose(Exception):
    """Peer connected and closed without sending any bytes.

    Issue #1652: the daemon's liveness connect-probe
    (gateway-socket-connect-probe.py) connects then closes with no payload
    on every tick. Treating that empty-recv as a malformed JSON payload made
    the listener log `decision=deny reason_code=invalid_payload` plus a
    `send_failed peer_gone=BrokenPipeError` for each probe — a large share of
    the ~9.6 MB log churn in the crash-loop. The accept loop maps this to an
    expected, no-op close: no deny log, no response attempt.
    """


def _recv_json(conn: socket.socket) -> dict[str, Any]:
    data = conn.recv(MAX_SOCKET_BYTES + 1)
    if len(data) > MAX_SOCKET_BYTES:
        raise ValueError("oversize")
    if not data:
        # Connect-probe / peer-closed-before-send: an empty datagram is not
        # a malformed payload, it's "nothing was sent". Signal it distinctly
        # so the handler can treat it as expected and stay quiet.
        raise _ProbeClose()
    payload = json.loads(data.decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("payload_not_object")
    return payload


def _peer_credentials(conn: socket.socket) -> tuple[int, int, int]:
    raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    pid, uid, gid = struct.unpack("3i", raw)
    return int(pid), int(uid), int(gid)


class ClientPreflightError(Exception):
    def __init__(self, reason_code: str, message: str = "") -> None:
        super().__init__(message or reason_code)
        self.reason_code = reason_code
        self.message = message or reason_code


def _format_client_preflight_error(exc: ClientPreflightError) -> str:
    # Format contract (r3 spec): "body file <reason_code>: <message>".
    # The smoke harness greps for the leading "body file " prefix and the
    # reason_code; keep both stable.
    return f"body file {exc.reason_code}: {exc.message}"


_INLINE_FILE_FLAGS: dict[str, tuple[str, str]] = {
    "create": ("--body-file", "--body"),
    "update": ("--body-file", "--body"),
    "done": ("--note-file", "--note"),
    "cancel": ("--note-file", "--note"),
    "handoff": ("--note-file", "--note"),
}


def _client_preflight_error(reason_code: str, message: str = "") -> ClientPreflightError:
    return ClientPreflightError(reason_code, message)


def _read_inline_text(path_text: str) -> str:
    if not path_text:
        raise _client_preflight_error("invalid_argv", "invalid argv: file path is empty")
    path = Path(path_text).expanduser()

    # O_NOFOLLOW: refuse to follow a symlink at the body-file path.
    # O_NONBLOCK: required so that opening a FIFO returns immediately
    # without waiting for a writer (a FIFO open without O_NONBLOCK blocks
    # indefinitely). For regular files O_NONBLOCK is a no-op.
    # Combined with the S_ISREG check below this rejects FIFOs, devices,
    # sockets, and symlink redirection in one shot — read_bytes() on a
    # FIFO can hang indefinitely and on /dev/zero would read until
    # INLINE_BODY_CAP_BYTES.
    open_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(str(path), open_flags)
    except FileNotFoundError as exc:
        raise _client_preflight_error("body_file_not_found", f"not found: {path_text}") from exc
    except PermissionError as exc:
        raise _client_preflight_error("body_file_unreadable", f"unreadable under client UID: {exc.strerror}") from exc
    except OSError as exc:
        # O_NOFOLLOW on a symlink raises ELOOP; treat as unreadable rather
        # than disclose the symlink shape.
        raise _client_preflight_error("body_file_unreadable", f"unreadable under client UID: {exc.strerror}") from exc

    try:
        try:
            st = os.fstat(fd)
        except OSError as exc:
            raise _client_preflight_error("body_file_unreadable", f"unreadable under client UID: {exc.strerror}") from exc

        if not stat.S_ISREG(st.st_mode):
            # FIFO / device / socket / directory — read_bytes() would block
            # or read unbounded. Reject before any I/O.
            raise _client_preflight_error("body_file_unreadable", f"not a regular file: {path_text}")

        if st.st_size > INLINE_BODY_CAP_BYTES:
            raise _client_preflight_error(
                "body_file_too_large",
                f"too large for inline transport: {st.st_size} > {INLINE_BODY_CAP_BYTES}",
            )

        # Bounded read: cap+1 bytes is enough to detect "would exceed cap"
        # if a racing writer grew the file between fstat and read. This is
        # defense-in-depth against the S_ISREG check being bypassed on an
        # exotic filesystem.
        try:
            raw = os.read(fd, INLINE_BODY_CAP_BYTES + 1)
        except OSError as exc:
            raise _client_preflight_error("body_file_unreadable", f"unreadable under client UID: {exc.strerror}") from exc
    finally:
        try:
            os.close(fd)
        except OSError:
            pass

    if len(raw) > INLINE_BODY_CAP_BYTES:
        raise _client_preflight_error(
            "body_file_too_large",
            f"too large for inline transport: {len(raw)} > {INLINE_BODY_CAP_BYTES}",
        )
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise _client_preflight_error("body_file_not_utf8", f"is not valid UTF-8: {exc}") from exc


def client_argv_normalize(argv: list[str]) -> list[str]:
    if not argv:
        return list(argv)

    file_flag, inline_flag = _INLINE_FILE_FLAGS.get(argv[0], ("", ""))
    if not file_flag:
        return list(argv)

    matches = [
        token
        for token in argv[1:]
        if token == file_flag or token.startswith(file_flag + "=")
    ]
    if len(matches) > 1:
        raise _client_preflight_error("duplicate_file_arg", f"duplicate flag: {file_flag} specified more than once")

    out = [argv[0]]
    i = 1
    while i < len(argv):
        token = argv[i]
        if token == file_flag:
            if i + 1 >= len(argv):
                raise _client_preflight_error("invalid_argv", f"invalid argv: {file_flag} requires a path")
            out.extend([inline_flag, _read_inline_text(argv[i + 1])])
            i += 2
            continue
        if token.startswith(file_flag + "="):
            path_text = token.split("=", 1)[1]
            if not path_text:
                raise _client_preflight_error("invalid_argv", f"invalid argv: {file_flag}= requires a path")
            out.extend([inline_flag, _read_inline_text(path_text)])
            i += 1
            continue
        out.append(token)
        i += 1

    return out


def _peer_map_from_env() -> dict[int, str]:
    raw = os.environ.get("BRIDGE_QUEUE_GATEWAY_PEERS", "").strip()
    peers: dict[int, str] = {}
    if not raw:
        return peers
    for item in raw.split(","):
        if not item.strip() or ":" not in item:
            continue
        uid_s, agent = item.split(":", 1)
        uid_s = uid_s.strip()
        agent = agent.strip()
        if uid_s.isdigit() and agent:
            _add_peer(peers, int(uid_s), agent)
    return peers


def _add_peer(peers: dict[int, str], uid: int, agent: str) -> None:
    existing = peers.get(uid)
    if existing and existing != agent:
        raise SystemExit(f"queue gateway duplicate peer uid: uid={uid} agents={existing},{agent}")
    peers[uid] = agent


def _peer_map_from_roster(script_dir: Path) -> dict[int, str]:
    peers = _peer_map_from_env()
    if peers:
        return peers
    bash = os.environ.get("BRIDGE_BASH_BIN", "bash")
    probe = r'''
source "$1/bridge-lib.sh"
bridge_load_roster
for agent in "${BRIDGE_AGENT_IDS[@]}"; do
  bridge_agent_linux_user_isolation_effective "$agent" || continue
  os_user="$(bridge_agent_os_user "$agent")"
  [ -n "$os_user" ] || continue
  uid="$(id -u "$os_user" 2>/dev/null || true)"
  [ -n "$uid" ] || continue
  printf '%s\t%s\n' "$uid" "$agent"
done
'''
    proc = subprocess.run(
        [bash, "-c", probe, "probe", str(script_dir)],
        text=True,
        capture_output=True,
        check=False,
        env=os.environ.copy(),
    )
    if proc.returncode != 0:
        raise SystemExit("queue gateway peer roster probe failed")
    for line in proc.stdout.splitlines():
        parts = line.split("\t", 1)
        if len(parts) != 2 or not parts[0].isdigit() or not parts[1]:
            continue
        _add_peer(peers, int(parts[0]), parts[1])
    return peers


def _socket_acl_refresh_seconds() -> float:
    raw = os.environ.get("BRIDGE_QUEUE_GATEWAY_ACL_REFRESH_SECONDS", str(SOCKET_ACL_REFRESH_SECONDS)).strip()
    try:
        value = float(raw)
    except ValueError:
        return SOCKET_ACL_REFRESH_SECONDS
    if value <= 0:
        return SOCKET_ACL_REFRESH_SECONDS
    return value


def _shared_group() -> grp.struct_group | None:
    """Return the ab-shared group struct, or None if not present on this host."""
    name = os.environ.get("BRIDGE_SHARED_GROUP", BRIDGE_SHARED_GROUP_DEFAULT).strip()
    try:
        return grp.getgrnam(name)
    except KeyError:
        return None


def _set_socket_group_mode(path: Path, live: bool = False) -> bool:
    """Set socket to group=ab-shared mode 0660 — no named-user ACEs needed.

    All isolated agent OS users are ab-shared members, so they get access
    automatically without per-agent setfacl. In live mode, a missing group
    is a hard failure. In smoke/dev mode, fall back to 0600 (owner-only).

    Returns True when the mode/group was (re)asserted, False when the socket
    path no longer exists on disk. Issue #1652: the daemon's clean_stale can
    rm the live listener's socket out from under us on a transient probe
    flap; the chown/chmod must NOT raise FileNotFoundError into the accept
    loop (which previously crashed the listener -> daemon respawn ->
    crash-loop). A missing socket path is a recoverable degrade, not a crash:
    the listener fd is still bound in the kernel and keeps serving, and the
    next refresh tick (or a daemon restart) reasserts perms once the path is
    back. The permissions contract (mode 0660 + ab-shared group, or 0600
    owner-only in dev) is unchanged when the path IS present.
    """
    g = _shared_group()
    if g is None:
        name = os.environ.get("BRIDGE_SHARED_GROUP", BRIDGE_SHARED_GROUP_DEFAULT).strip()
        if live:
            raise SystemExit(
                f"queue gateway socket requires group '{name}' (BRIDGE_SHARED_GROUP). "
                f"Create the group and add all isolated agent users to it, then restart the daemon."
            )
        try:
            os.chmod(path, 0o600)
        except FileNotFoundError:
            return False
        return True
    try:
        os.chown(path, -1, g.gr_gid)
        os.chmod(path, 0o660)
    except FileNotFoundError:
        return False
    return True


def _refresh_socket_perms(path: Path, peer_map: dict[int, str], script_dir: Path, live: bool = False) -> bool:
    """Refresh peer_map from roster and reassert group/mode on the socket.

    peer_map is kept current for SO_PEERCRED authorization in _handle_socket_request.
    The filesystem permission change (group mode) makes it self-healing on each tick.

    Returns the result of the group/mode reassert (see _set_socket_group_mode):
    True when reasserted, False when the socket path was transiently absent.
    The peer_map refresh always runs first so authorization stays current
    even when the fs perm reassert has to be skipped this tick.
    """
    latest = _peer_map_from_roster(script_dir)
    peer_map.clear()
    peer_map.update(latest)
    return _set_socket_group_mode(path, live=live)


def _task_row(home: str, task_id: int) -> sqlite3.Row | None:
    db = task_db_path(home)
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute(
            "SELECT id, assigned_to, created_by, claimed_by, status FROM tasks WHERE id = ?",
            (task_id,),
        ).fetchone()
    finally:
        conn.close()


def _set_option(argv: list[str], option: str, value: str) -> list[str]:
    out = [argv[0]]
    skip = False
    for token in argv[1:]:
        if skip:
            skip = False
            continue
        if token == option:
            skip = True
            continue
        if token.startswith(option + "="):
            continue
        out.append(token)
    out.extend([option, value])
    return out


def _is_file_arg_token(token: str) -> bool:
    flag_name = token.split("=", 1)[0]
    if flag_name in {"--body-file", "--note-file"}:
        return True
    return flag_name.startswith("--body-f") or flag_name.startswith("--note-f")


def _has_file_arg(argv: list[str]) -> bool:
    for token in argv[1:]:
        if _is_file_arg_token(token):
            return True
    return False


# Per-subcommand option tables for the strict task-id walker (finding 2a,
# r2 + r3 review). The original walker treated any first non-option token
# as the positional task id. r2 added the value-flag table to skip the
# token following `--note`/`--note-file`/etc., closing `done --note 60 12
# --agent forged`. r3 closes the prefix-abbreviation bypass: argparse's
# default `allow_abbrev=True` lets the inner parser expand `--note-f` →
# `--note-file`, but the gateway walker has no notion of abbreviations,
# so under r2 the gateway saw `--note-f` as an unknown value-less flag
# and read `60` as the positional, while the inner parser consumed `60`
# into `--note-file` and operated on `12`. The r3 contract: bridge-queue.py
# subparsers all set `allow_abbrev=False`, AND this walker rejects any
# long option that is not in the known-flag set for the subcommand. Both
# halves are required — relying on either alone re-opens the smuggling
# window if the other side regresses.
#
# `_VALUE_FLAGS_BY_SUBCMD` lists long flags that *consume the following
# token*. `_BOOLEAN_FLAGS_BY_SUBCMD` lists flags that do not. The union
# is the gateway-allowed set of long options for each subcommand; any
# other long option is rejected as `unknown_option`. Both `--flag value`
# and `--flag=value` forms are tolerated. The `--body-file` /
# `--note-file` value flags are also gated upstream by `_has_file_arg`,
# but appear here so the walker is honest if that gate is ever loosened.
#
# This table must stay in sync with bridge-queue.py's per-subcommand
# argparse definitions. When you add or rename a flag in bridge-queue.py,
# update the matching entry below in the same change.
_VALUE_FLAGS_BY_SUBCMD: dict[str, frozenset[str]] = {
    "claim": frozenset({"--agent", "--lease-seconds"}),
    "done": frozenset({"--agent", "--note", "--note-file"}),
    "cancel": frozenset({"--actor", "--note", "--note-file"}),
    "update": frozenset({
        "--actor",
        "--title",
        "--status",
        "--priority",
        "--note",
        "--body",
        "--body-file",
    }),
    "handoff": frozenset({"--from", "--to", "--note", "--note-file"}),
    "show": frozenset({"--format"}),
}

_BOOLEAN_FLAGS_BY_SUBCMD: dict[str, frozenset[str]] = {
    "claim": frozenset(),
    "done": frozenset(),
    "cancel": frozenset(),
    "update": frozenset(),
    "handoff": frozenset(),
    "show": frozenset(),
}


def _extract_positional_task_id(argv: list[str]) -> tuple[int | None, str]:
    """Return the parsed positional task id for the given subcommand argv.

    Walks the argv with knowledge of which flags consume the next token,
    so `done --note 60 12` returns (12, "ok"). Returns:
      * (None, "task_id_required") — no bare positional found, or the
        first one is not an integer, or the argv is empty / has no
        recognizable subcommand.
      * (None, "unknown_option") — the argv contains a long option
        that is not in the gateway-known set for this subcommand.
        Treated fail-closed: argparse abbreviations or any other novel
        flag must reach an explicit allow-list update before they pass.
      * (task_id, "ok") on success.
    """
    if not argv:
        return None, "task_id_required"
    subcmd = argv[0]
    value_flags = _VALUE_FLAGS_BY_SUBCMD.get(subcmd, frozenset())
    boolean_flags = _BOOLEAN_FLAGS_BY_SUBCMD.get(subcmd, frozenset())
    known_flags = value_flags | boolean_flags
    skip_next = False
    for token in argv[1:]:
        if skip_next:
            skip_next = False
            continue
        if token == "--":
            # Conservative: the queue parser does not use `--`, so treat a
            # bare `--` as no-positional rather than guessing.
            return None, "task_id_required"
        if token.startswith("--"):
            # Strip an inline `=value` so `--flag=value` and `--flag` map
            # to the same flag-name lookup.
            flag_name = token.split("=", 1)[0]
            if flag_name not in known_flags:
                # r3 finding 2a: reject anything the gateway can't classify.
                # If the inner parser (bridge-queue.py) honored argparse's
                # default abbreviation expansion, an unknown prefix here
                # would let a later token be smuggled into either the
                # positional slot or a value slot. Fail closed; clients
                # must spell flags exactly.
                return None, "unknown_option"
            if "=" in token:
                # `--flag=value` self-contains the value; the next token
                # is still positional.
                continue
            if flag_name in value_flags:
                skip_next = True
            continue
        if token.startswith("-") and len(token) > 1:
            # Short options are not used by bridge-queue subcommands the
            # gateway forwards. Reject so the walker stays in sync with
            # what the inner parser actually accepts.
            return None, "unknown_option"
        try:
            return int(token), "ok"
        except ValueError:
            return None, "task_id_required"
    return None, "task_id_required"


def authorize_and_rewrite(home: str, peer_agent: str, argv: list[str]) -> tuple[bool, str, list[str]]:
    if not argv:
        return False, "empty_argv", argv
    subcmd = argv[0]
    if subcmd in {"init", "cron-ready", "daemon-step", "note-nudge", "events"}:
        return False, f"{subcmd}_denied", argv
    if _has_file_arg(argv):
        return False, "file_arg_denied", argv

    if subcmd == "create":
        # Rooms ACL (P1b): gate the inter-agent create on shared-room membership
        # when rooms_acl=enforce. The actor is the SO_PEERCRED peer_agent (NOT
        # the client --from), so an iso agent cannot send as another room
        # member. Default-off / no-rooms / exempt -> pass (no behavior change).
        acl_ok, acl_reason = _rooms_acl_gate_create(home, peer_agent, argv)
        if not acl_ok:
            return False, acl_reason, argv
        return True, "ok", _set_option(argv, "--from", peer_agent)
    if subcmd in {"inbox", "find-open", "claim", "done"}:
        rewritten = _set_option(argv, "--agent", peer_agent)
        if subcmd in {"claim", "done"}:
            task_id, parse_reason = _extract_positional_task_id(argv)
            if task_id is None:
                return False, parse_reason, argv
            row = _task_row(home, task_id)
            if row is None:
                return False, "task_not_found", argv
            assigned = str(row["assigned_to"] or "")
            claimed = str(row["claimed_by"] or "")
            if subcmd == "claim" and assigned != peer_agent:
                return False, "claim_not_assigned", argv
            if subcmd == "done" and assigned != peer_agent and claimed != peer_agent:
                return False, "done_not_owner", argv
        return True, "ok", rewritten
    if subcmd == "summary":
        return True, "ok", _set_option(argv, "--agent", peer_agent)
    if subcmd == "show":
        task_id, parse_reason = _extract_positional_task_id(argv)
        if task_id is None:
            return False, parse_reason, argv
        row = _task_row(home, task_id)
        if row is None:
            return False, "task_not_found", argv
        if peer_agent not in {str(row["assigned_to"] or ""), str(row["created_by"] or ""), str(row["claimed_by"] or "")}:
            return False, "show_not_visible", argv
        return True, "ok", argv
    if subcmd in {"cancel", "update"}:
        task_id, parse_reason = _extract_positional_task_id(argv)
        if task_id is None:
            return False, parse_reason, argv
        row = _task_row(home, task_id)
        if row is None:
            return False, "task_not_found", argv
        if peer_agent not in {str(row["assigned_to"] or ""), str(row["created_by"] or ""), str(row["claimed_by"] or "")}:
            return False, f"{subcmd}_not_owner", argv
        return True, "ok", _set_option(argv, "--actor", peer_agent)
    if subcmd == "handoff":
        task_id, parse_reason = _extract_positional_task_id(argv)
        if task_id is None:
            return False, parse_reason, argv
        row = _task_row(home, task_id)
        if row is None:
            return False, "task_not_found", argv
        if peer_agent not in {str(row["assigned_to"] or ""), str(row["claimed_by"] or "")}:
            return False, "handoff_not_owner", argv
        return True, "ok", _set_option(argv, "--from", peer_agent)

    return False, "subcmd_denied", argv


def gateway_log(subcmd: str, peer_uid: int, peer_agent: str, decision: str, reason_code: str, request_id: str) -> None:
    fields = {
        "subcmd": subcmd or "-",
        "peer_uid": str(peer_uid),
        "peer_agent": peer_agent or "-",
        "decision": decision,
        "reason_code": reason_code,
        "request_id": request_id or "-",
    }
    print("queue_gateway " + " ".join(f"{key}={value}" for key, value in fields.items()), file=sys.stderr, flush=True)


def _deny_response(request_id: str, reason_code: str, exit_code: int = 2) -> dict[str, Any]:
    # The reason_code on the wire MUST be a public-safe code; leaky internal
    # codes (e.g. task_not_found, done_not_owner) are mapped here so callers
    # don't need to remember to map at every emit site. The detailed code is
    # still recorded server-side via gateway_log() for operator triage.
    return {
        "id": request_id,
        "request_id": request_id,
        "exit_code": exit_code,
        "stdout": "",
        "stderr": "queue gateway denied\n",
        "decision": "deny",
        "reason_code": _public_reason_code(reason_code),
    }


def _handle_socket_request(
    conn: socket.socket,
    queue_script: Path,
    home: str,
    peer_map: dict[int, str],
    script_dir: Path,
) -> None:
    peer_uid = -1
    peer_agent = ""
    request_id = "-"
    subcmd = "-"
    try:
        _pid, peer_uid, _gid = _peer_credentials(conn)
        peer_agent = peer_map.get(peer_uid, "")
        if not peer_agent:
            peer_map.update(_peer_map_from_roster(script_dir))
            peer_agent = peer_map.get(peer_uid, "")
        request = _recv_json(conn)
        request_id = str(request.get("id") or "-")
        argv = request.get("argv", [])
        cwd = str(request.get("cwd") or os.getcwd())
        if not isinstance(argv, list) or not all(isinstance(item, str) for item in argv):
            gateway_log(subcmd, peer_uid, peer_agent, "deny", "invalid_argv", request_id)
            _safe_send_json(conn, _deny_response(request_id, "invalid_argv"))
            return
        subcmd = argv[0] if argv else "-"
        if not peer_agent:
            gateway_log(subcmd, peer_uid, peer_agent, "deny", "unknown_peer", request_id)
            _safe_send_json(conn, _deny_response(request_id, "unknown_peer"))
            return
        ok, reason, rewritten = authorize_and_rewrite(home, peer_agent, argv)
        if not ok:
            gateway_log(subcmd, peer_uid, peer_agent, "deny", reason, request_id)
            _safe_send_json(conn, _deny_response(request_id, reason))
            return
        gateway_log(subcmd, peer_uid, peer_agent, "allow", reason, request_id)
        response = {"id": request_id}
        # peer_agent is the SO_PEERCRED-authenticated actor; hand it to the queue
        # child as the rooms-ACL trusted actor (P1b). For non-create subcommands
        # this is harmless (cmd_create is the only consumer).
        # #1792: forward the cron run id (attribution metadata only) so an iso
        # cron child's create is stamped origin=cron:<id>; never the actor.
        request_cron_run_id = str(request.get("cron_run_id", "") or "").strip()
        response.update(
            run_queue(queue_script, rewritten, cwd, trusted_actor=peer_agent, cron_run_id=request_cron_run_id)
        )
        _safe_send_json(conn, response)
    except _ProbeClose:
        # Issue #1652: liveness connect-probe (or any peer that connected and
        # closed without sending) — expected, not a protocol violation. Do
        # NOT log a deny and do NOT attempt a response (the peer is already
        # gone, which is what produced the per-probe BrokenPipeError spam).
        return
    except ValueError as exc:
        reason = "oversize_payload" if str(exc) == "oversize" else "invalid_payload"
        gateway_log(subcmd, peer_uid, peer_agent, "deny", reason, request_id)
        _safe_send_json(conn, _deny_response(request_id, reason))
    except Exception:
        gateway_log(subcmd, peer_uid, peer_agent, "deny", "exception", request_id)
        _safe_send_json(conn, _deny_response(request_id, "exception", exit_code=1))


def _socket_type() -> int:
    sock_type = getattr(socket, "SOCK_SEQPACKET", None)
    if sock_type is None:
        raise SystemExit("SOCK_SEQPACKET is required for the queue gateway socket transport")
    return int(sock_type)


def cmd_socket_client(args: argparse.Namespace) -> int:
    if not _socket_transport_supported():
        # Fail-closed on non-Linux: peer auth on the listener side cannot
        # work, so refuse here too. Operators must select the file
        # transport (BRIDGE_GATEWAY_TRANSPORT=file) on this platform.
        print(f"queue gateway socket unavailable: {SOCKET_LINUX_ONLY_MESSAGE}", file=sys.stderr)
        return 1
    home = bridge_home(args.bridge_home)
    path = gateway_socket_path(home)
    request_id = f"{int(time.time() * 1000)}-{os.getpid()}-{secrets.token_hex(6)}"
    try:
        normalized_argv = client_argv_normalize(list(args.argv))
    except ClientPreflightError as exc:
        print(_format_client_preflight_error(exc), file=sys.stderr)
        return 2

    payload: dict[str, Any] = {
        "id": request_id,
        "argv": normalized_argv,
        "cwd": os.getcwd(),
        "created_at": now_iso(),
    }
    # #1792: forward the cron run id (attribution metadata only) so an iso cron
    # child creating through the SOCKET gateway is stamped origin=cron:<id> —
    # same as the file client. Strictly weaker than the client-asserted --from;
    # the server never lets it influence the trusted-actor / ACL decision.
    cron_run_id = os.environ.get("BRIDGE_CRON_RUN_ID", "").strip()
    if cron_run_id:
        payload["cron_run_id"] = cron_run_id
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    if len(data) > MAX_SOCKET_BYTES:
        exc = _client_preflight_error(
            "body_file_too_large",
            f"too large for inline transport: request payload {len(data)} > {MAX_SOCKET_BYTES}",
        )
        print(_format_client_preflight_error(exc), file=sys.stderr)
        return 2

    try:
        with socket.socket(socket.AF_UNIX, _socket_type()) as sock:
            sock.settimeout(float(args.timeout))
            sock.connect(str(path))
            sock.sendall(data)
            response = _recv_json(sock)
    except OSError as exc:
        print(f"queue gateway socket unavailable: {exc.strerror or type(exc).__name__}", file=sys.stderr)
        return 1
    except (ValueError, _ProbeClose):
        # _ProbeClose: the server closed without sending any bytes — from the
        # client's POV that is just an empty/invalid response (issue #1652
        # split the empty-recv case out of ValueError on the server side; the
        # client must keep treating it as a failed call, not crash uncaught).
        print("queue gateway socket returned an invalid response", file=sys.stderr)
        return 1

    # defense-in-depth: the local server is trusted by the security model,
    # but we still validate its protocol output before printing or using it.
    # A malicious or replaced local server (or a future protocol bug) must
    # not be able to inject arbitrary stderr text or crash the client with a
    # non-int exit_code.
    stdout = str(response.get("stdout", ""))
    stderr = str(response.get("stderr", ""))
    if stdout:
        sys.stdout.write(stdout)
    if response.get("decision") == "deny" and response.get("reason_code"):
        raw_reason = str(response.get("reason_code") or "")
        if raw_reason in _PUBLIC_REASON_CODES:
            shown_reason = raw_reason
        else:
            print(
                f"queue_gateway client_unknown_reason raw={raw_reason!r}",
                file=sys.stderr,
                flush=True,
            )
            shown_reason = "internal_error"
        sys.stderr.write(f"queue gateway denied: {shown_reason}\n")
    elif stderr:
        sys.stderr.write(stderr)

    raw_exit = response.get("exit_code", 1)
    try:
        return int(raw_exit)
    except (TypeError, ValueError):
        print(
            f"queue_gateway client_invalid_exit_code raw={raw_exit!r}",
            file=sys.stderr,
            flush=True,
        )
        return 1


def cmd_socket_server(args: argparse.Namespace) -> int:
    if not _socket_transport_supported():
        # Fail-closed on non-Linux: SO_PEERCRED is the only credential
        # mechanism implemented here. Refuse to start so credential
        # checks cannot silently bypass.
        raise SystemExit(SOCKET_LINUX_ONLY_MESSAGE)
    home = bridge_home(args.bridge_home)
    if not ensure_runtime_layout(home, strict=True):
        return 1
    path = gateway_socket_path(home)
    queue_script = Path(args.queue_script).expanduser()
    script_dir = queue_script.resolve().parent
    peer_map = _peer_map_from_roster(script_dir)
    is_live = str(gateway_runtime_root()) == LIVE_GATEWAY_RUNTIME_ROOT
    acl_refresh_seconds = _socket_acl_refresh_seconds()
    next_acl_refresh = time.monotonic() + acl_refresh_seconds
    running = True

    def cleanup() -> None:
        try:
            if path.exists() and stat.S_ISSOCK(os.lstat(path).st_mode):
                path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass

    def stop(_signum: int | None = None, _frame: Any | None = None) -> None:
        nonlocal running
        running = False
        cleanup()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    atexit.register(cleanup)

    if path.exists() or path.is_symlink():
        st = os.lstat(path)
        if stat.S_ISSOCK(st.st_mode):
            path.unlink()
        else:
            raise SystemExit(f"refuse non-socket at {path}")

    with socket.socket(socket.AF_UNIX, _socket_type()) as server:
        old_umask = os.umask(0o177)
        try:
            server.bind(str(path))
        finally:
            os.umask(old_umask)
        _set_socket_group_mode(path, live=is_live)
        server.listen(64)
        server.settimeout(1.0)
        print(f"queue_gateway_listener socket={path}", file=sys.stderr, flush=True)
        while running:
            try:
                conn, _addr = server.accept()
            except (TimeoutError, socket.timeout):
                if time.monotonic() >= next_acl_refresh:
                    # Issue #1652: a missing socket path here (daemon rm'd it
                    # on a transient probe flap) must degrade, not crash —
                    # _refresh_socket_perms returns False instead of raising
                    # FileNotFoundError. Log the skip once per tick for
                    # operator triage; the bound fd keeps serving and the
                    # next tick reasserts perms once the path is back.
                    if not _refresh_socket_perms(path, peer_map, script_dir, live=is_live):
                        print(
                            f"queue_gateway socket_perms_skip reason=socket_path_missing path={path}",
                            file=sys.stderr,
                            flush=True,
                        )
                    next_acl_refresh = time.monotonic() + acl_refresh_seconds
                continue
            except OSError:
                if running:
                    raise
                break
            # Per-peer scope: a single bad peer (oversize frame, partial
            # frame followed by close, broken pipe on response) MUST NOT
            # kill the accept loop. _handle_socket_request swallows its
            # own send failures via _safe_send_json; this outer guard
            # catches anything else (peer disconnect raised inside
            # _recv_json, an unexpected exception in authorize_and_rewrite,
            # etc.) so the listener stays up. The `with conn:` context
            # ensures the fd is closed even on exception.
            try:
                with conn:
                    conn.settimeout(SOCKET_TIMEOUT_SECONDS)
                    _handle_socket_request(
                        conn, queue_script, home, peer_map, script_dir
                    )
            except Exception as exc:  # noqa: BLE001 — listener survival > propagation
                try:
                    print(
                        f"queue_gateway handler_error type={type(exc).__name__}",
                        file=sys.stderr,
                        flush=True,
                    )
                except OSError:
                    pass
    cleanup()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    client = sub.add_parser("client")
    client.add_argument("--root", required=True)
    client.add_argument("--agent", required=True)
    client.add_argument("--timeout", type=float, default=45.0)
    client.add_argument("--poll", type=float, default=0.2)
    client.add_argument("argv", nargs=argparse.REMAINDER)
    client.set_defaults(handler=cmd_client)

    socket_client = sub.add_parser("socket-client")
    socket_client.add_argument("--bridge-home")
    socket_client.add_argument("--timeout", type=float, default=SOCKET_TIMEOUT_SECONDS)
    socket_client.add_argument("argv", nargs=argparse.REMAINDER)
    socket_client.set_defaults(handler=cmd_socket_client)

    socket_server = sub.add_parser("socket-server")
    socket_server.add_argument("--bridge-home")
    socket_server.add_argument("--queue-script", required=True)
    socket_server.set_defaults(handler=cmd_socket_server)

    serve_once = sub.add_parser("serve-once")
    serve_once.add_argument("--root", required=True)
    serve_once.add_argument("--queue-script", required=True)
    serve_once.add_argument("--max-requests", type=int, default=100)
    serve_once.set_defaults(handler=cmd_serve_once)

    runtime_id = sub.add_parser("print-runtime-id")
    runtime_id.add_argument("--bridge-home")
    runtime_id.set_defaults(handler=cmd_print_runtime_id)

    # #1837 fix 4 — the daemon-down primitive A3 (#1833) consumes. Tri-state
    # `up`/`down`/`unknown`; `unknown` when the caller's UID cannot read
    # daemon.pid (iso boundary) so status presentation never false-reports
    # `down`.
    daemon_liveness = sub.add_parser("daemon-liveness")
    daemon_liveness.add_argument("--bridge-home")
    daemon_liveness.add_argument("--format", choices=("text", "json"), default="text")
    daemon_liveness.set_defaults(handler=cmd_daemon_liveness)

    verify = sub.add_parser("verify-runtime")
    verify.add_argument("--bridge-home")
    verify.add_argument("--format", choices=("text", "json"), default="text")
    verify.set_defaults(handler=cmd_verify_runtime)

    ensure = sub.add_parser("ensure-runtime")
    ensure.add_argument("--bridge-home")
    ensure.add_argument("--strict", action="store_true")
    ensure.set_defaults(handler=cmd_ensure_runtime)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "argv", None):
        args.argv = [item for item in args.argv if item != "--"]
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
