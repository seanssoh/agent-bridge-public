#!/usr/bin/env python3
"""Telegram polling relay daemon for Agent Bridge.

The relay owns exactly one Telegram Bot API polling stream for a token and
serves local plugin clients over a Unix socket. Tokens are only read from a
token file; the token value is never accepted on argv.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import signal
import socket
import socketserver
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_BUFFER_TTL_SECONDS = 24 * 60 * 60
DEFAULT_MAX_BUFFERED = 1000


def json_dumps(payload: Any) -> str:
    return json.dumps(payload, ensure_ascii=False, sort_keys=True)


def now_ts() -> float:
    return time.time()


def read_token_file(path: Path) -> str:
    st = path.stat()
    if stat.S_IMODE(st.st_mode) & 0o077:
        raise SystemExit(f"token file must not be group/world readable: {path}")
    token = path.read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit(f"token file is empty: {path}")
    return token


def token_hash_for_value(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]


def token_hash_for_file(path: Path) -> str:
    return token_hash_for_value(read_token_file(path))


def atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, mode)
    tmp.replace(path)
    os.chmod(path, mode)


def audit_record(
    *,
    action: str,
    target: str,
    detail: dict[str, Any] | None = None,
) -> None:
    audit_log = os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
    if not audit_log:
        return
    audit_script = Path(__file__).resolve().parent.parent / "bridge-audit.py"
    if not audit_script.exists():
        return
    cmd = [
        sys.executable,
        str(audit_script),
        "write",
        "--file",
        audit_log,
        "--actor",
        "telegram-relay",
        "--action",
        action,
        "--target",
        target,
    ]
    for key, value in sorted((detail or {}).items()):
        cmd.extend(["--detail", f"{key}={value}"])
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=False)
    except Exception:
        return


def read_json_lines(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    entries: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                entries.append(payload)
    return entries


def pid_running(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def rpc_call(socket_path: Path, request: dict[str, Any], timeout: float = 5.0) -> dict[str, Any]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(str(socket_path))
        payload = (json_dumps(request) + "\n").encode("utf-8")
        client.sendall(payload)
        chunks: list[bytes] = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
    raw = b"".join(chunks).split(b"\n", 1)[0]
    if not raw:
        raise RuntimeError("empty RPC response")
    response = json.loads(raw.decode("utf-8"))
    if not isinstance(response, dict):
        raise RuntimeError("RPC response was not an object")
    return response


def wait_for_relay_ready(
    *,
    socket_path: Path,
    proc: subprocess.Popen[Any],
    timeout: float = 5.0,
) -> tuple[bool, str]:
    deadline = now_ts() + timeout
    last_error = ""
    while now_ts() < deadline:
        rc = proc.poll()
        if rc is not None:
            return False, f"relay exited before becoming healthy: exit_code={rc}"
        if socket_path.exists():
            try:
                health = rpc_call(socket_path, {"verb": "health"}, timeout=0.5)
                if health.get("ok"):
                    return True, ""
                last_error = f"health returned ok=false: {health}"
            except Exception as exc:  # noqa: BLE001 - reported as startup detail.
                last_error = f"{exc.__class__.__name__}: {exc}"
        time.sleep(0.1)
    if last_error:
        return False, f"timed out waiting for relay health at {socket_path}: {last_error}"
    return False, f"timed out waiting for relay socket: {socket_path}"


class ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


class TelegramRelay:
    def __init__(
        self,
        *,
        token_file: Path,
        state_dir: Path,
        socket_path: Path,
        log_file: Path,
        api_base_url: str,
        poll_timeout: int,
        buffer_ttl_seconds: int,
        max_buffered: int,
    ) -> None:
        self.token_file = token_file
        self.state_dir = state_dir
        self.socket_path = socket_path
        self.log_file = log_file
        self.api_base_url = api_base_url.rstrip("/")
        self.poll_timeout = poll_timeout
        self.buffer_ttl_seconds = buffer_ttl_seconds
        self.max_buffered = max_buffered

        self.token = read_token_file(token_file)
        self.token_hash = token_hash_for_value(self.token)
        self.cursor_file = state_dir / "cursor"
        self.state_lock_file = state_dir / "state.lock"
        self.buffer_file = state_dir / "buffered.jsonl"
        self.pid_file = state_dir / "pid"
        self.lock_file = state_dir / "relay.lock"

        self.stop_event = threading.Event()
        self.reload_event = threading.Event()
        self.condition = threading.Condition()
        self.token_lock = threading.Lock()
        self.clients: dict[str, dict[str, Any]] = {}
        self.client_cursors: dict[str, int] = {}
        self.buffer: list[dict[str, Any]] = []
        self.cursor = 0
        self.last_get_updates_ts = 0.0
        self.server: ThreadingUnixServer | None = None
        self.poller_thread: threading.Thread | None = None
        self.lock_handle: Any = None

    def log(self, message: str) -> None:
        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        line = f"[{time.strftime('%Y-%m-%dT%H:%M:%S%z')}] {message}\n"
        with self.log_file.open("a", encoding="utf-8") as handle:
            handle.write(line)

    def acquire_lock_or_exit(self) -> bool:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.lock_handle = self.lock_file.open("a+", encoding="utf-8")
        try:
            fcntl.flock(self.lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.log("another relay is active for this token-hash, exiting")
            return False
        return True

    def lock_still_held(self) -> bool:
        if self.lock_handle is None:
            return False
        try:
            fcntl.flock(self.lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError):
            return False
        return True

    @contextlib.contextmanager
    def state_file_lock(self) -> Any:
        self.state_lock_file.parent.mkdir(parents=True, exist_ok=True)
        with self.state_lock_file.open("a+", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            yield

    def pruned_buffer_entries(self, entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
        cutoff = now_ts() - max(0, self.buffer_ttl_seconds)
        pruned = [
            entry
            for entry in entries
            if float(entry.get("received_ts") or 0) >= cutoff
        ]
        if len(pruned) > self.max_buffered:
            pruned = pruned[-self.max_buffered :]
        return pruned

    def load_state(self) -> None:
        with self.state_file_lock():
            if self.cursor_file.exists():
                raw = self.cursor_file.read_text(encoding="utf-8").strip()
                if raw.isdigit():
                    self.cursor = int(raw)
            self.buffer = read_json_lines(self.buffer_file)
            self.prune_buffer(force=True, persist=True)

    def persist_cursor(self) -> None:
        atomic_write(self.cursor_file, f"{self.cursor}\n")

    def persist_buffer(self, entries: list[dict[str, Any]] | None = None) -> None:
        if os.environ.get("BRIDGE_TELEGRAM_RELAY_FAULT_BUFFER_WRITE") == "1":
            raise RuntimeError("test fault: buffer write failed before cursor advance")
        buffer_entries = self.buffer if entries is None else entries
        lines = "".join(json_dumps(entry) + "\n" for entry in buffer_entries)
        atomic_write(self.buffer_file, lines)

    def prune_buffer(self, force: bool = False, persist: bool = True) -> None:
        next_buffer = self.pruned_buffer_entries(self.buffer)
        changed = next_buffer != self.buffer
        if persist and (force or changed):
            self.persist_buffer(next_buffer)
        self.buffer = next_buffer

    def reload_token(self) -> None:
        new_token = read_token_file(self.token_file)
        new_hash = token_hash_for_value(new_token)
        with self.token_lock:
            old_hash = self.token_hash
            if new_hash != old_hash:
                self.log(f"token hash changed after SIGHUP; stopping old_hash={old_hash} new_hash={new_hash}")
                audit_record(
                    action="telegram_relay_token_rotated",
                    target=old_hash,
                    detail={"old_hash": old_hash, "new_hash": new_hash},
                )
                self.stop_event.set()
                with self.condition:
                    self.condition.notify_all()
                return
            self.token = new_token
        self.log("reloaded token file after SIGHUP")

    def api_url(self, method: str, query: dict[str, Any] | None = None) -> str:
        with self.token_lock:
            token = self.token
        token_part = urllib.parse.quote(token, safe=":")
        url = f"{self.api_base_url}/bot{token_part}/{method}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        return url

    def telegram_get_updates(self) -> list[dict[str, Any]]:
        query = {"offset": self.cursor + 1, "timeout": self.poll_timeout}
        with urllib.request.urlopen(
            self.api_url("getUpdates", query),
            timeout=max(5, self.poll_timeout + 5),
        ) as response:
            payload = json.loads(response.read().decode("utf-8"))
        self.last_get_updates_ts = now_ts()
        if not payload.get("ok"):
            raise RuntimeError("Telegram getUpdates returned ok=false")
        updates = payload.get("result", [])
        if not isinstance(updates, list):
            return []
        return [item for item in updates if isinstance(item, dict)]

    def telegram_send_message(self, request: dict[str, Any]) -> dict[str, Any]:
        body: dict[str, Any] = {
            "chat_id": request.get("chat_id"),
            "text": request.get("text"),
        }
        if request.get("reply_to") not in (None, ""):
            body["reply_to_message_id"] = request.get("reply_to")
        for key in ("parse_mode", "disable_web_page_preview", "disable_notification"):
            if key in request:
                body[key] = request[key]
        data = json_dumps(body).encode("utf-8")
        http_request = urllib.request.Request(
            self.api_url("sendMessage"),
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(http_request, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))
        if not isinstance(payload, dict):
            raise RuntimeError("Telegram sendMessage response was not an object")
        return payload

    def append_update(self, update: dict[str, Any]) -> None:
        update_id = int(update.get("update_id") or 0)
        if update_id <= 0:
            return
        with self.condition:
            with self.state_file_lock():
                if any(int(entry.get("update_id") or 0) == update_id for entry in self.buffer):
                    if update_id > self.cursor:
                        self.cursor = update_id
                        self.persist_cursor()
                    return
                entry = {
                    "update_id": update_id,
                    "received_ts": now_ts(),
                    "delivered_to": [],
                    "update": update,
                }
                next_buffer = self.pruned_buffer_entries([*self.buffer, entry])
                next_cursor = max(self.cursor, update_id)
                self.persist_buffer(next_buffer)
                self.buffer = next_buffer
                self.cursor = next_cursor
                self.persist_cursor()
            self.condition.notify_all()

    def poll_loop(self) -> None:
        backoff = 1.0
        last_prune = 0.0
        while not self.stop_event.is_set():
            try:
                updates = self.telegram_get_updates()
                backoff = 1.0
                for update in updates:
                    self.append_update(update)
                if now_ts() - last_prune >= 60:
                    self.prune_buffer()
                    last_prune = now_ts()
            except urllib.error.HTTPError as exc:
                if exc.code == 409:
                    self.log("Telegram getUpdates conflict; backing off")
                    if not self.lock_still_held():
                        self.log("relay lock was lost after Telegram conflict; stopping")
                        self.stop_event.set()
                        break
                    self.stop_event.wait(backoff)
                    backoff = min(backoff * 2, 60)
                else:
                    self.log(f"Telegram getUpdates HTTP error: {exc.code}")
                    self.stop_event.wait(backoff)
                    backoff = min(backoff * 2, 30)
            except Exception as exc:  # noqa: BLE001 - daemon must keep polling.
                self.log(f"Telegram getUpdates error: {exc.__class__.__name__}: {exc}")
                self.stop_event.wait(backoff)
                backoff = min(backoff * 2, 30)

    def entry_matches_filter(self, entry: dict[str, Any], channel_filter: Any) -> bool:
        if not isinstance(channel_filter, dict) or not channel_filter:
            return True
        chat_id = channel_filter.get("chat_id")
        if chat_id in (None, ""):
            return True
        update = entry.get("update")
        if not isinstance(update, dict):
            return False
        message = update.get("message") or update.get("edited_message") or {}
        if not isinstance(message, dict):
            return False
        chat = message.get("chat") or {}
        if not isinstance(chat, dict):
            return False
        return str(chat.get("id")) == str(chat_id)

    def handle_request(self, request: dict[str, Any]) -> dict[str, Any]:
        verb = str(request.get("verb") or request.get("method") or "")
        if verb == "register":
            client_id = str(request.get("client_id") or "")
            if not client_id:
                return {"ok": False, "error": "client_id required"}
            with self.condition:
                self.clients[client_id] = {
                    "channel_filter": request.get("channel_filter") or {},
                    "registered_ts": now_ts(),
                }
                self.client_cursors.setdefault(client_id, int(request.get("since_id") or 0))
            return {"ok": True}

        if verb == "unregister":
            client_id = str(request.get("client_id") or "")
            with self.condition:
                self.clients.pop(client_id, None)
                self.client_cursors.pop(client_id, None)
            return {"ok": True}

        if verb == "recv":
            return self.handle_recv(request)

        if verb == "send_message":
            payload = self.telegram_send_message(request)
            return {"ok": True, "response": payload}

        if verb == "health":
            with self.condition:
                return {
                    "ok": True,
                    "token_hash": self.token_hash,
                    "polling_cursor": self.cursor,
                    "connected_clients": len(self.clients),
                    "last_get_updates_ts": self.last_get_updates_ts,
                    "buffered_updates": len(self.buffer),
                }

        return {"ok": False, "error": f"unsupported verb: {verb}"}

    def handle_recv(self, request: dict[str, Any]) -> dict[str, Any]:
        client_id = str(request.get("client_id") or "")
        if not client_id:
            return {"ok": False, "error": "client_id required"}
        timeout = float(request.get("timeout_seconds") or 0)
        since_id = int(request.get("since_id") or 0)
        deadline = now_ts() + max(0.0, timeout)

        with self.condition:
            self.clients.setdefault(client_id, {"channel_filter": {}, "registered_ts": now_ts()})
            while True:
                cursor = max(self.client_cursors.get(client_id, 0), since_id)
                channel_filter = self.clients.get(client_id, {}).get("channel_filter") or {}
                selected: list[dict[str, Any]] = []
                changed = False
                for entry in self.buffer:
                    update_id = int(entry.get("update_id") or 0)
                    delivered_to = entry.setdefault("delivered_to", [])
                    if update_id <= cursor or client_id in delivered_to:
                        continue
                    if not self.entry_matches_filter(entry, channel_filter):
                        continue
                    delivered_to.append(client_id)
                    selected_update = dict(entry.get("update") or {})
                    selected_update["delivered_to"] = list(delivered_to)
                    selected.append(selected_update)
                    self.client_cursors[client_id] = max(self.client_cursors.get(client_id, 0), update_id)
                    changed = True
                if changed:
                    with self.state_file_lock():
                        self.persist_buffer()
                if selected or timeout <= 0:
                    return {"ok": True, "updates": selected, "cursor": self.client_cursors.get(client_id, cursor)}
                remaining = deadline - now_ts()
                if remaining <= 0:
                    return {"ok": True, "updates": [], "cursor": self.client_cursors.get(client_id, cursor)}
                self.condition.wait(timeout=min(remaining, 1.0))

    def start(self) -> int:
        if not self.acquire_lock_or_exit():
            return 0
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        self.load_state()
        atomic_write(self.pid_file, f"{os.getpid()}\n")
        try:
            if self.socket_path.exists():
                self.socket_path.unlink()
            self.server = ThreadingUnixServer(str(self.socket_path), RelayRequestHandler)
            self.server.relay = self  # type: ignore[attr-defined]
            os.chmod(self.socket_path, 0o600)
            server_thread = threading.Thread(target=self.server.serve_forever, name="telegram-relay-ipc", daemon=True)
            server_thread.start()
            self.poller_thread = threading.Thread(target=self.poll_loop, name="telegram-relay-poller", daemon=True)
            self.poller_thread.start()
            self.log(f"relay started token_hash={self.token_hash} socket={self.socket_path}")
            while not self.stop_event.is_set():
                if self.reload_event.is_set():
                    self.reload_event.clear()
                    self.reload_token()
                time.sleep(0.2)
        finally:
            self.shutdown()
        return 0

    def shutdown(self) -> None:
        self.stop_event.set()
        with self.condition:
            self.condition.notify_all()
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
        if self.poller_thread is not None:
            self.poller_thread.join(timeout=2)
        with self.state_file_lock():
            self.prune_buffer(force=True, persist=True)
        if self.socket_path.exists():
            self.socket_path.unlink()
        if self.pid_file.exists():
            self.pid_file.unlink()
        self.log("relay stopped")


class RelayRequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        relay: TelegramRelay = self.server.relay  # type: ignore[attr-defined]
        for raw in self.rfile:
            try:
                request = json.loads(raw.decode("utf-8"))
                if not isinstance(request, dict):
                    raise ValueError("request must be a JSON object")
                response = relay.handle_request(request)
            except Exception as exc:  # noqa: BLE001 - keep client protocol stable.
                response = {"ok": False, "error": f"{exc.__class__.__name__}: {exc}"}
            self.wfile.write((json_dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


def daemonize_if_requested(args: argparse.Namespace) -> None:
    if not args.background:
        return
    if os.fork() > 0:
        raise SystemExit(0)
    os.setsid()
    if os.fork() > 0:
        raise SystemExit(0)
    sys.stdin.flush()
    sys.stdout.flush()
    sys.stderr.flush()
    with open(os.devnull, "rb", 0) as read_null, open(args.log_file, "ab", 0) as log_handle:
        os.dup2(read_null.fileno(), sys.stdin.fileno())
        os.dup2(log_handle.fileno(), sys.stdout.fileno())
        os.dup2(log_handle.fileno(), sys.stderr.fileno())


def state_paths(state_root: Path, token_hash: str) -> tuple[Path, Path, Path]:
    state_dir = state_root / token_hash
    return state_dir, state_root / f"{token_hash}.sock", state_dir / "relay.log"


def register_token(state_root: Path, token_file: Path) -> str:
    token_hash = token_hash_for_file(token_file)
    state_root.mkdir(parents=True, exist_ok=True)
    tokens_file = state_root / "tokens.list"
    rows: dict[str, str] = {}
    if tokens_file.exists():
        for line in tokens_file.read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                rows[parts[0]] = parts[1]
    rows = {
        existing_hash: existing_file
        for existing_hash, existing_file in rows.items()
        if existing_file != str(token_file) or existing_hash == token_hash
    }
    rows[token_hash] = str(token_file)
    text = "".join(f"{key}\t{value}\n" for key, value in sorted(rows.items()))
    atomic_write(tokens_file, text)
    return token_hash


def command_run(args: argparse.Namespace) -> int:
    daemonize_if_requested(args)
    relay = TelegramRelay(
        token_file=Path(args.token_file).expanduser(),
        state_dir=Path(args.state_dir).expanduser(),
        socket_path=Path(args.socket_path).expanduser(),
        log_file=Path(args.log_file).expanduser(),
        api_base_url=args.api_base_url,
        poll_timeout=args.poll_timeout,
        buffer_ttl_seconds=args.buffer_ttl_seconds,
        max_buffered=args.max_buffered,
    )

    def handle_term(_signum: int, _frame: Any) -> None:
        relay.stop_event.set()

    def handle_hup(_signum: int, _frame: Any) -> None:
        relay.reload_event.set()

    signal.signal(signal.SIGTERM, handle_term)
    signal.signal(signal.SIGINT, handle_term)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, handle_hup)
    return relay.start()


def command_start(args: argparse.Namespace) -> int:
    token_file = Path(args.token_file).expanduser()
    token_hash = register_token(Path(args.state_root).expanduser(), token_file)
    state_dir, socket_path, log_file = state_paths(Path(args.state_root).expanduser(), token_hash)

    if socket_path.exists():
        try:
            health = rpc_call(socket_path, {"verb": "health"}, timeout=1.0)
            if health.get("ok"):
                print(f"token_hash: {token_hash}")
                print("started: no")
                print("status: already-running")
                print(f"socket: {socket_path}")
                return 0
        except Exception:
            pass

    run_args = [
        sys.executable,
        str(Path(__file__).resolve()),
        "run",
        "--token-file",
        str(token_file),
        "--state-dir",
        str(state_dir),
        "--socket-path",
        str(socket_path),
        "--log-file",
        str(log_file),
        "--api-base-url",
        args.api_base_url,
        "--poll-timeout",
        str(args.poll_timeout),
        "--buffer-ttl-seconds",
        str(args.buffer_ttl_seconds),
        "--max-buffered",
        str(args.max_buffered),
        "--foreground",
    ]
    if args.foreground:
        print(f"token_hash: {token_hash}", flush=True)
        print("started: foreground", flush=True)
        print(f"socket: {socket_path}", flush=True)
        os.execv(sys.executable, run_args)

    state_dir.mkdir(parents=True, exist_ok=True)
    with log_file.open("ab") as log_handle, open(os.devnull, "rb") as devnull:
        proc = subprocess.Popen(
            run_args,
            stdin=devnull,
            stdout=log_handle,
            stderr=log_handle,
            start_new_session=True,
        )
    ready, detail = wait_for_relay_ready(socket_path=socket_path, proc=proc)
    print(f"token_hash: {token_hash}")
    if not ready:
        print("started: no")
        print(f"status: failed")
        print(f"detail: {detail}")
        print(f"log: {log_file}")
        return 1
    print("started: yes")
    print(f"pid: {proc.pid}")
    print(f"socket: {socket_path}")
    return 0


def command_rpc(args: argparse.Namespace) -> int:
    request = json.loads(args.request_json)
    if not isinstance(request, dict):
        raise SystemExit("request JSON must be an object")
    response = rpc_call(Path(args.socket_path).expanduser(), request, timeout=args.timeout)
    print(json_dumps(response))
    return 0


def command_health(args: argparse.Namespace) -> int:
    state_root = Path(args.state_root).expanduser()
    _state_dir, socket_path, _log_file = state_paths(state_root, args.token_hash)
    response = rpc_call(socket_path, {"verb": "health"}, timeout=args.timeout)
    if args.json:
        print(json_dumps(response))
    else:
        for key, value in response.items():
            print(f"{key}: {value}")
    return 0 if response.get("ok") else 1


def command_stop(args: argparse.Namespace) -> int:
    state_root = Path(args.state_root).expanduser()
    state_dir, _socket_path, _log_file = state_paths(state_root, args.token_hash)
    pid_file = state_dir / "pid"
    if not pid_file.exists():
        print(f"token_hash: {args.token_hash}")
        print("stopped: no")
        print("status: not-running")
        return 0
    raw = pid_file.read_text(encoding="utf-8").strip()
    if not raw.isdigit():
        raise SystemExit(f"invalid pid file: {pid_file}")
    pid = int(raw)
    if pid_running(pid):
        os.kill(pid, signal.SIGTERM)
        deadline = now_ts() + args.wait_seconds
        while now_ts() < deadline and pid_running(pid):
            time.sleep(0.1)
    print(f"token_hash: {args.token_hash}")
    print("stopped: yes")
    print(f"pid: {pid}")
    return 0


def command_status(args: argparse.Namespace) -> int:
    state_root = Path(args.state_root).expanduser()
    tokens_file = state_root / "tokens.list"
    hashes: set[str] = set()
    if tokens_file.exists():
        for line in tokens_file.read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            hashes.add(line.split("\t", 1)[0])
    if state_root.exists():
        for child in state_root.iterdir():
            if child.is_dir():
                hashes.add(child.name)
    print(f"state_root: {state_root}")
    if not hashes:
        print("relays: none")
        return 0
    print("relays:")
    for token_hash in sorted(hashes):
        state_dir, socket_path, _log_file = state_paths(state_root, token_hash)
        pid_file = state_dir / "pid"
        cursor_file = state_dir / "cursor"
        pid = pid_file.read_text(encoding="utf-8").strip() if pid_file.exists() else ""
        running = pid.isdigit() and pid_running(int(pid))
        cursor = cursor_file.read_text(encoding="utf-8").strip() if cursor_file.exists() else "0"
        clients = "-"
        if socket_path.exists():
            try:
                health = rpc_call(socket_path, {"verb": "health"}, timeout=0.5)
                clients = str(health.get("connected_clients", "-"))
            except Exception:
                clients = "?"
        print(
            f"  {token_hash} | pid={pid or '-'} | running={'yes' if running else 'no'} "
            f"| socket={socket_path} | cursor={cursor} | connected_clients={clients}"
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Agent Bridge Telegram relay daemon")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run")
    run.add_argument("--token-file", required=True)
    run.add_argument("--state-dir", required=True)
    run.add_argument("--socket-path", required=True)
    run.add_argument("--log-file", required=True)
    run.add_argument("--api-base-url", default=os.environ.get("BRIDGE_TELEGRAM_API_BASE_URL", "https://api.telegram.org"))
    run.add_argument("--poll-timeout", type=int, default=25)
    run.add_argument("--buffer-ttl-seconds", type=int, default=DEFAULT_BUFFER_TTL_SECONDS)
    run.add_argument("--max-buffered", type=int, default=DEFAULT_MAX_BUFFERED)
    mode = run.add_mutually_exclusive_group()
    mode.add_argument("--foreground", action="store_true", default=True)
    mode.add_argument("--background", action="store_true")
    run.set_defaults(func=command_run)

    start = sub.add_parser("start")
    start.add_argument("--token-file", required=True)
    start.add_argument("--state-root", required=True)
    start.add_argument("--foreground", action="store_true")
    start.add_argument("--api-base-url", default=os.environ.get("BRIDGE_TELEGRAM_API_BASE_URL", "https://api.telegram.org"))
    start.add_argument("--poll-timeout", type=int, default=25)
    start.add_argument("--buffer-ttl-seconds", type=int, default=DEFAULT_BUFFER_TTL_SECONDS)
    start.add_argument("--max-buffered", type=int, default=DEFAULT_MAX_BUFFERED)
    start.set_defaults(func=command_start)

    token_hash = sub.add_parser("token-hash")
    token_hash.add_argument("--token-file", required=True)
    token_hash.set_defaults(func=lambda args: (print(token_hash_for_file(Path(args.token_file).expanduser())) or 0))

    rpc = sub.add_parser("rpc")
    rpc.add_argument("--socket-path", required=True)
    rpc.add_argument("--request-json", required=True)
    rpc.add_argument("--timeout", type=float, default=5.0)
    rpc.set_defaults(func=command_rpc)

    health = sub.add_parser("health")
    health.add_argument("--state-root", required=True)
    health.add_argument("--token-hash", required=True)
    health.add_argument("--timeout", type=float, default=5.0)
    health.add_argument("--json", action="store_true")
    health.set_defaults(func=command_health)

    stop = sub.add_parser("stop")
    stop.add_argument("--state-root", required=True)
    stop.add_argument("--token-hash", required=True)
    stop.add_argument("--wait-seconds", type=float, default=5.0)
    stop.set_defaults(func=command_stop)

    status = sub.add_parser("status")
    status.add_argument("--state-root", required=True)
    status.set_defaults(func=command_status)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
