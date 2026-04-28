#!/usr/bin/env python3
"""File-backed queue RPC gateway for isolated static agents."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


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
    response = {
        "id": str(request.get("id", path.name.split(".", 1)[0])),
        "exit_code": int(proc.returncode),
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "processed_at": now_iso(),
    }
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

    serve_once = sub.add_parser("serve-once")
    serve_once.add_argument("--root", required=True)
    serve_once.add_argument("--queue-script", required=True)
    serve_once.add_argument("--max-requests", type=int, default=100)
    serve_once.set_defaults(handler=cmd_serve_once)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "argv", None):
        args.argv = [item for item in args.argv if item != "--"]
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
