#!/usr/bin/env python3
"""Helper for scripts/smoke/1697-a2a-net-status.sh (#1697).

Read-only assertions over the `agb a2a net-status --json` document. Pure stdin
JSON inspection — this helper NEVER touches A2A state, spawns no daemon, and
writes nothing. Subcommands (all read stdin, exit 0/1 with a one-line reason):

  field <dotted.path> <expected>   assert snapshot[path] == expected (str cmp)
  has-keys <comma,sep,keys>        assert top-level keys all present
  substrate-checked <kind>         assert substrate.checked == kind
  substrate-no-tailscale           assert substrate dict has NO tailscale* keys
  substrate-no-warp                assert substrate dict has NO warp* keys
  receiver-healthz <token>         assert receiver.healthz == token
  no-secrets <comma,sep,secrets>   assert none of the secret tokens appear
  free-port                        print a free loopback TCP port
  net-status-held <config> <bind> <port> <timeout>
                                   hold a real listen socket on (bind, port)
                                   that accepts-then-drops (the non-hairpin WARP
                                   symptom), run `agb a2a net-status --json`
                                   against <config> under the loopback test-bind,
                                   and print the JSON snapshot to stdout (the
                                   #1701 healthz-consistency case)

Exit 0 on pass, 1 on failure (prints the reason for the smoke log).
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
A2A_CLI = REPO_ROOT / "bridge-a2a.py"


def _free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def _hold_and_drop_server(bind: str, port: int, stop: threading.Event) -> socket.socket:
    """Hold a real listen socket on (bind, port) that accepts then drops.

    Models a healthy WARP receiver whose listen socket is genuinely held but is
    NOT reachable by the self-probe: every accepted connection is closed without
    an HTTP reply, so the GET /healthz self-probe sees a reset/timeout (the
    non-hairpin symptom), while the OS reports the address in use (EADDRINUSE) to
    the #1701 socket-held fallback inside cmd_healthz — which net-status reuses.

    Deliberately NO SO_REUSEADDR: the fallback relies on a plain bind raising
    EADDRINUSE while this socket is held, exactly as the production probe does.
    """
    srv = socket.socket(socket.AF_INET6 if ":" in bind else socket.AF_INET,
                        socket.SOCK_STREAM)
    srv.bind((bind, port))
    srv.listen(16)
    srv.settimeout(0.2)

    def _accept_loop() -> None:
        while not stop.is_set():
            try:
                conn, _ = srv.accept()
            except OSError:
                continue
            try:
                conn.close()  # drop immediately: no HTTP reply -> probe fails
            except OSError:
                pass

    threading.Thread(target=_accept_loop, daemon=True).start()
    return srv


def _net_status_held(config: str, bind: str, port: int, timeout: str) -> int:
    """Run `agb a2a net-status --json` while a listen socket is held.

    Emits the snapshot JSON on stdout so the shell driver can assert
    receiver.healthz == "healthy" (the #1701 consistency: a held-but-unreachable
    WARP receiver must NOT be reported healthz_timeout). The held socket is alive
    for the whole net-status run (net-status delegates the healthz verdict to the
    same cmd_healthz that owns the socket-held fallback).
    """
    stop = threading.Event()
    srv = _hold_and_drop_server(bind, port, stop)
    time.sleep(0.1)  # let the accept thread be ready before the probe
    try:
        env = dict(os.environ)  # noqa: iso-helper-boundary  # smoke fixture: copies the test process env to pass BRIDGE_A2A_* to the subprocess; not a controller->iso boundary write
        env["BRIDGE_A2A_ALLOW_TEST_BIND"] = "1"
        env["BRIDGE_A2A_CONFIG"] = config
        proc = subprocess.run(
            [sys.executable, str(A2A_CLI), "net-status", "--json",
             "--probe-timeout", timeout],
            capture_output=True, text=True, timeout=60, env=env, check=False,
        )
        sys.stdout.write(proc.stdout)
        return 0 if proc.returncode == 0 else 1
    finally:
        stop.set()
        try:
            srv.close()
        except OSError:
            pass


def _load_a2a_module():
    """Import bridge-a2a.py by file path (hyphenated name isn't import-able).

    The repo root must be on sys.path so bridge-a2a.py's own
    `import bridge_a2a_common` resolves regardless of the caller's cwd.
    """
    import importlib.util
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))
    spec = importlib.util.spec_from_file_location("bridge_a2a_under_test", str(A2A_CLI))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _substrate_iface_fail(preexisting_warp_error: str) -> int:
    """Drive `_netstat_substrate` for a warp-mesh config whose interface
    enumeration FAILS, and print the resulting substrate dict as JSON.

    This unit-drives the exact #1697 BLOCKING-2 fix: `error` is pre-seeded to
    None, so a `setdefault` on the iface-enum failure path would be a no-op and
    silently report `error=None`. We monkeypatch `local_interface_addresses` to
    raise an A2AError (code iface_enum_failed) and assert the substrate records a
    NON-None error.

    `preexisting_warp_error`:
      - "none"  → warp_cli resolves + warp status is connected, so no prior
                  error exists; the iface-enum failure MUST populate `error`.
      - "warp"  → warp_cli is forced absent so a prior, more-specific warp_cli
                  error is already set; the iface-enum failure must PRESERVE it
                  (the `or` keeps the first error, never clobbers it with None or
                  a less-specific message).
    """
    mod = _load_a2a_module()
    a2a = mod.a2a

    # Always make interface enumeration fail.
    def _raise_iface(*_a, **_k):
        raise a2a.A2AError("simulated iface enumeration failure",
                           code="iface_enum_failed")
    a2a.local_interface_addresses = _raise_iface  # type: ignore[assignment]

    if preexisting_warp_error == "warp":
        # Force a prior warp_cli error: resolve_warp_cli returns None so the
        # substrate sets error="warp-cli not found ..." BEFORE the iface path.
        a2a.resolve_warp_cli = lambda: None  # type: ignore[assignment]
    else:
        # No prior error: warp_cli resolves and status reports connected.
        a2a.resolve_warp_cli = lambda: "/usr/bin/warp-cli"  # type: ignore[assignment]
        a2a._run_warp_cli = lambda *_a, **_k: "Status update: Connected"  # type: ignore[assignment]
        a2a._warp_status_is_connected = lambda *_a, **_k: True  # type: ignore[assignment]

    cfg = {"transport": {"kind": "cloudflare-warp-mesh"},
           "listen": {"address": "100.96.0.5", "port": 8787}}
    sub = mod._netstat_substrate(cfg, "100.96.0.5", a2a.TRANSPORT_CLOUDFLARE_WARP_MESH)
    print(json.dumps(sub, ensure_ascii=False))
    return 0


def _load() -> dict:
    raw = sys.stdin.read()
    try:
        return json.loads(raw)
    except (ValueError, TypeError) as exc:  # pragma: no cover - smoke diagnostic
        print(f"not-json: {exc}: {raw[:200]!r}")
        sys.exit(1)


def _dig(doc: dict, dotted: str):
    cur = doc
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return ("__MISSING__", False)
        cur = cur[part]
    return (cur, True)


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: <subcommand> [args...]")
        return 2
    cmd, rest = argv[0], argv[1:]

    if cmd == "free-port":
        print(_free_port())
        return 0

    if cmd == "net-status-held":
        config, bind, port_s, timeout = rest[0], rest[1], rest[2], rest[3]
        return _net_status_held(config, bind, int(port_s), timeout)

    if cmd == "substrate-iface-fail":
        # rest[0] = "none" | "warp" (whether a prior warp_cli error exists)
        return _substrate_iface_fail(rest[0] if rest else "none")

    if cmd == "substrate-error-nonnull":
        # Assert the stdin substrate JSON has a NON-None, non-empty error string,
        # and (when an expected substring is given) that it is preserved.
        sub = _load()
        err = sub.get("error")
        if err is None or err == "":
            print(f"substrate.error is None/empty (expected a probe-failure string): {sub}")
            return 1
        if len(rest) >= 1 and rest[0] and rest[0] not in str(err):
            print(f"substrate.error={err!r} does not preserve expected {rest[0]!r}")
            return 1
        print("ok")
        return 0

    if cmd == "has-keys":
        doc = _load()
        want = [k for k in rest[0].split(",") if k]
        missing = [k for k in want if k not in doc]
        if missing:
            print(f"missing top-level keys: {missing}")
            return 1
        print("ok")
        return 0

    if cmd == "field":
        doc = _load()
        dotted, expected = rest[0], rest[1]
        val, found = _dig(doc, dotted)
        if not found:
            print(f"path not found: {dotted}")
            return 1
        if str(val) != expected:
            print(f"{dotted}={val!r} != expected {expected!r}")
            return 1
        print("ok")
        return 0

    if cmd == "substrate-checked":
        doc = _load()
        sub = doc.get("substrate", {})
        if sub.get("checked") != rest[0]:
            print(f"substrate.checked={sub.get('checked')!r} != {rest[0]!r}")
            return 1
        print("ok")
        return 0

    if cmd in ("substrate-no-tailscale", "substrate-no-warp"):
        doc = _load()
        sub = doc.get("substrate", {})
        needle = "tailscale" if cmd.endswith("tailscale") else "warp"
        offenders = [k for k in sub if needle in k.lower()]
        # `checked` legitimately CONTAINS the transport name as its value, but
        # we inspect KEY names here, and `checked` is a fixed key (not a probe
        # result), so it never matches the needle substring.
        if offenders:
            print(f"substrate has unexpected {needle} keys: {offenders}")
            return 1
        print("ok")
        return 0

    if cmd == "receiver-healthz":
        doc = _load()
        rec = doc.get("receiver", {})
        if str(rec.get("healthz")) != rest[0]:
            print(f"receiver.healthz={rec.get('healthz')!r} != {rest[0]!r}")
            return 1
        print("ok")
        return 0

    if cmd == "no-secrets":
        raw = sys.stdin.read()
        secrets = [s for s in rest[0].split(",") if s]
        leaked = [s for s in secrets if s in raw]
        if leaked:
            print(f"SECRET LEAK: {leaked}")
            return 1
        print("ok")
        return 0

    print(f"unknown subcommand: {cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
