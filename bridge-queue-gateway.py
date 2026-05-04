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
import shutil
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
SOCKET_LINUX_ONLY_MESSAGE = (
    "queue gateway socket transport requires Linux (SO_PEERCRED); "
    "use BRIDGE_GATEWAY_TRANSPORT=file on this platform"
)


def _socket_transport_supported() -> bool:
    """Linux-only fail-closed gate for the socket transport.

    SO_PEERCRED is the only credential mechanism this gateway implements;
    it is Linux-specific.  Returning False on any other platform forces
    callers to either fall back to the file transport or fail with a
    recognizable error rather than silently bypass peer auth.
    """
    return sys.platform.startswith("linux") and hasattr(socket, "SO_PEERCRED")


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}.{secrets.token_hex(4)}")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
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


def agent_root(root: Path, agent: str) -> Path:
    return root / agent


def request_dir(root: Path, agent: str) -> Path:
    return agent_root(root, agent) / "requests"


def response_dir(root: Path, agent: str) -> Path:
    return agent_root(root, agent) / "responses"


def cmd_client(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser()
    req_dir = request_dir(root, args.agent)
    resp_dir = response_dir(root, args.agent)
    req_dir.mkdir(parents=True, exist_ok=True)
    resp_dir.mkdir(parents=True, exist_ok=True)

    request_id = f"{int(time.time() * 1000)}-{os.getpid()}-{secrets.token_hex(6)}"
    request_path = req_dir / f"{request_id}.request.json"
    response_path = resp_dir / f"{request_id}.json"
    atomic_write_json(
        request_path,
        {
            "id": request_id,
            "agent": args.agent,
            "argv": list(args.argv),
            "cwd": os.getcwd(),
            "created_at": now_iso(),
        },
    )

    deadline = time.monotonic() + max(1.0, float(args.timeout))
    poll = max(0.05, float(args.poll))
    while time.monotonic() < deadline:
        if response_path.exists():
            payload = load_json(response_path)
            try:
                response_path.unlink()
            except OSError:
                pass
            stdout = str(payload.get("stdout", ""))
            stderr = str(payload.get("stderr", ""))
            if stdout:
                sys.stdout.write(stdout)
            if stderr:
                sys.stderr.write(stderr)
            return int(payload.get("exit_code", 1))
        time.sleep(poll)

    try:
        request_path.unlink()
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


def run_queue(queue_script: Path, argv: list[str], cwd: str | None) -> dict[str, Any]:
    child_env = os.environ.copy()
    child_env["BRIDGE_QUEUE_GATEWAY_SERVER"] = "1"
    child_env.pop("BRIDGE_GATEWAY_PROXY", None)

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
    response.update(run_queue(queue_script, argv, cwd))
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
    if child.st_uid != current_uid or stat.S_IMODE(child.st_mode) != 0o711:
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
    os.chmod(inst, 0o711)
    os.chown(inst, os.getuid(), os.getgid())


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
        print(
            "queue gateway runtime setup requires root once; run: "
            f"sudo install -d -m 0755 -o root -g root {gateway_runtime_root()} && "
            f"sudo install -d -m 0711 -o {_user_name(os.getuid())} -g {_group_name(os.getgid())} {gateway_instance_dir(home)}",
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


def _recv_json(conn: socket.socket) -> dict[str, Any]:
    data = conn.recv(MAX_SOCKET_BYTES + 1)
    if len(data) > MAX_SOCKET_BYTES:
        raise ValueError("oversize")
    payload = json.loads(data.decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("payload_not_object")
    return payload


def _peer_credentials(conn: socket.socket) -> tuple[int, int, int]:
    raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    pid, uid, gid = struct.unpack("3i", raw)
    return int(pid), int(uid), int(gid)


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
            peers[int(uid_s)] = agent
    return peers


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
        return {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t", 1)
        if len(parts) != 2 or not parts[0].isdigit() or not parts[1]:
            continue
        peers[int(parts[0])] = parts[1]
    return peers


def _set_socket_acl(path: Path, peer_map: dict[int, str]) -> None:
    """Restrict socket access to the controller plus known isolated peer UIDs."""
    os.chmod(path, 0o600)
    current_uid = os.getuid()
    specs = []
    for uid, agent in sorted(peer_map.items()):
        if uid == current_uid:
            continue
        try:
            user = pwd.getpwuid(uid).pw_name
        except KeyError as exc:
            raise SystemExit(f"queue gateway socket peer has no local user: uid={uid} agent={agent}") from exc
        specs.append(f"u:{user}:rw")

    if not specs:
        return

    setfacl = shutil.which("setfacl")
    if not setfacl:
        raise SystemExit("queue gateway socket peer ACL requires setfacl for isolated UID peers")

    proc = subprocess.run(
        [setfacl, "-m", ",".join(specs + ["m::rw"]), str(path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or f"setfacl exited {proc.returncode}"
        raise SystemExit(f"queue gateway socket peer ACL failed: {detail}")


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


def _has_file_arg(argv: list[str]) -> bool:
    for token in argv[1:]:
        if token in {"--body-file", "--note-file"}:
            return True
        if token.startswith("--body-file=") or token.startswith("--note-file="):
            return True
    return False


# Per-subcommand option tables for the strict task-id walker (finding 2a,
# r2 review). The earlier _task_id() walked the argv looking for the first
# non-option token, which let an option *value* be misread as the
# positional task id. Example: `done --note 60 12 --agent forged` would
# extract 60 (the value of --note) for authorization while the real
# bridge-queue.py invocation operated on task 12.
#
# Each entry below names which long flags accept a value (and therefore
# consume the following token) for the named subcommand. Boolean flags do
# not appear here. Both `--flag value` and `--flag=value` forms must be
# tolerated. argparse-style abbreviations are NOT honored here — the
# gateway only forwards full flag names that the bridge-queue.py parser
# accepts, so an unknown `--<flag>` is treated as a *value-less* flag (it
# will fail downstream, but cannot smuggle a value into the positional
# slot).
#
# This table must stay in sync with bridge-queue.py's per-subcommand
# argparse definitions for `claim`, `done`, `cancel`, `update`, `handoff`,
# and `show`. The `--body-file` / `--note-file` flags are intentionally
# rejected before this walker runs (see _has_file_arg), so they are listed
# here only to keep the walker honest if the file-arg gate is ever
# loosened.
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


def _extract_positional_task_id(argv: list[str]) -> int | None:
    """Return the parsed positional task id for the given subcommand argv.

    Walks the argv with knowledge of which flags consume the next token,
    so `done --note 60 12` returns 12, not 60. Returns None when:
      * the argv has no recognizable subcommand (caller should reject);
      * the first bare positional is not an integer;
      * the argv contains no bare positional.
    """
    if not argv:
        return None
    subcmd = argv[0]
    value_flags = _VALUE_FLAGS_BY_SUBCMD.get(subcmd, frozenset())
    skip_next = False
    for token in argv[1:]:
        if skip_next:
            skip_next = False
            continue
        if token == "--":
            # Conservative: the queue parser does not use `--`, so treat a
            # bare `--` as no-positional rather than guessing.
            return None
        if token.startswith("--"):
            if "=" in token:
                # `--flag=value` self-contains the value; the next token
                # is still positional.
                continue
            if token in value_flags:
                skip_next = True
            continue
        if token.startswith("-") and len(token) > 1:
            # Short options are not used by bridge-queue subcommands the
            # gateway forwards. Skip without consuming a value to avoid
            # accidentally swallowing a real positional.
            continue
        try:
            return int(token)
        except ValueError:
            return None
    return None


def authorize_and_rewrite(home: str, peer_agent: str, argv: list[str]) -> tuple[bool, str, list[str]]:
    if not argv:
        return False, "empty_argv", argv
    subcmd = argv[0]
    if subcmd in {"init", "cron-ready", "daemon-step", "note-nudge", "events"}:
        return False, f"{subcmd}_denied", argv
    if _has_file_arg(argv):
        return False, "file_arg_denied", argv

    if subcmd == "create":
        return True, "ok", _set_option(argv, "--from", peer_agent)
    if subcmd in {"inbox", "find-open", "claim", "done"}:
        rewritten = _set_option(argv, "--agent", peer_agent)
        if subcmd in {"claim", "done"}:
            task_id = _extract_positional_task_id(argv)
            if task_id is None:
                return False, "task_id_required", argv
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
        task_id = _extract_positional_task_id(argv)
        if task_id is None:
            return False, "task_id_required", argv
        row = _task_row(home, task_id)
        if row is None:
            return False, "task_not_found", argv
        if peer_agent not in {str(row["assigned_to"] or ""), str(row["created_by"] or ""), str(row["claimed_by"] or "")}:
            return False, "show_not_visible", argv
        return True, "ok", argv
    if subcmd in {"cancel", "update"}:
        task_id = _extract_positional_task_id(argv)
        if task_id is None:
            return False, "task_id_required", argv
        row = _task_row(home, task_id)
        if row is None:
            return False, "task_not_found", argv
        if peer_agent not in {str(row["assigned_to"] or ""), str(row["created_by"] or ""), str(row["claimed_by"] or "")}:
            return False, f"{subcmd}_not_owner", argv
        return True, "ok", _set_option(argv, "--actor", peer_agent)
    if subcmd == "handoff":
        task_id = _extract_positional_task_id(argv)
        if task_id is None:
            return False, "task_id_required", argv
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
            _safe_send_json(conn, {"id": request_id, "exit_code": 2, "stdout": "", "stderr": "queue gateway denied\n"})
            return
        subcmd = argv[0] if argv else "-"
        if not peer_agent:
            gateway_log(subcmd, peer_uid, peer_agent, "deny", "unknown_peer", request_id)
            _safe_send_json(conn, {"id": request_id, "exit_code": 2, "stdout": "", "stderr": "queue gateway denied\n"})
            return
        ok, reason, rewritten = authorize_and_rewrite(home, peer_agent, argv)
        if not ok:
            gateway_log(subcmd, peer_uid, peer_agent, "deny", reason, request_id)
            _safe_send_json(conn, {"id": request_id, "exit_code": 2, "stdout": "", "stderr": "queue gateway denied\n"})
            return
        gateway_log(subcmd, peer_uid, peer_agent, "allow", reason, request_id)
        response = {"id": request_id}
        response.update(run_queue(queue_script, rewritten, cwd))
        _safe_send_json(conn, response)
    except ValueError as exc:
        reason = "oversize" if str(exc) == "oversize" else "invalid_payload"
        gateway_log(subcmd, peer_uid, peer_agent, "deny", reason, request_id)
        _safe_send_json(conn, {"id": request_id, "exit_code": 2, "stdout": "", "stderr": "queue gateway denied\n"})
    except Exception:
        gateway_log(subcmd, peer_uid, peer_agent, "deny", "exception", request_id)
        _safe_send_json(conn, {"id": request_id, "exit_code": 1, "stdout": "", "stderr": "queue gateway error\n"})


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
    payload = {
        "id": request_id,
        "argv": list(args.argv),
        "cwd": os.getcwd(),
        "created_at": now_iso(),
    }
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    if len(data) > MAX_SOCKET_BYTES:
        raise SystemExit("queue gateway request too large")

    try:
        with socket.socket(socket.AF_UNIX, _socket_type()) as sock:
            sock.settimeout(float(args.timeout))
            sock.connect(str(path))
            sock.sendall(data)
            response = _recv_json(sock)
    except OSError as exc:
        print(f"queue gateway socket unavailable: {exc.strerror or type(exc).__name__}", file=sys.stderr)
        return 1
    except ValueError:
        print("queue gateway socket returned an invalid response", file=sys.stderr)
        return 1

    stdout = str(response.get("stdout", ""))
    stderr = str(response.get("stderr", ""))
    if stdout:
        sys.stdout.write(stdout)
    if stderr:
        sys.stderr.write(stderr)
    return int(response.get("exit_code", 1))


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
    peer_map = _peer_map_from_roster(queue_script.resolve().parent)
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
        _set_socket_acl(path, peer_map)
        server.listen(64)
        server.settimeout(1.0)
        print(f"queue_gateway_listener socket={path}", file=sys.stderr, flush=True)
        while running:
            try:
                conn, _addr = server.accept()
            except (TimeoutError, socket.timeout):
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
                        conn, queue_script, home, peer_map, queue_script.resolve().parent
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
