#!/usr/bin/env python3
"""Helper for the 1701-warp-healthz-socket-held smoke (file-as-argv sidecar).

Drives `bridge-handoffd.py healthz` against a controlled bind scenario so the
shell harness never needs a real WARP tunnel (which can't be stood up in CI) nor
a heredoc-stdin into python3 (footgun #11). The shell smoke calls one of:

  free-port
      Print a free loopback TCP port (the chosen receiver bind:port).

  run-healthz <config> <bind> <port> <mode> <timeout>
      Run the healthz probe with the listen socket in <mode>, capturing the real
      `cmd_healthz` exit code + reason word. Prints `RC=<n>` and `REASON=<word>`.

      <mode> = held
          A real listening socket is held on (bind, port) BEFORE the probe runs,
          but it never completes an HTTP exchange (it accepts the TCP connection
          then drops it without replying) — so the GET /healthz self-probe
          fails/times out exactly like a non-hairpinable WARP bind, while the
          listen socket IS genuinely held. This is the #1701 fix scenario: a
          healthy-but-unreachable-by-self receiver.

      <mode> = nothing
          NOTHING is listening on (bind, port). The HTTP probe gets connection
          refused AND the socket-held fallback binds cleanly (no EADDRINUSE) ->
          the teeth: a dead receiver must still report healthz_timeout.

The healthz probe always resolves bind/port from <config> under
BRIDGE_A2A_ALLOW_TEST_BIND=1 (loopback test-bind), so the transport.kind in the
config governs whether the socket-held fallback is consulted — the whole point
of the warp-only gating the smoke asserts.
"""

from __future__ import annotations

import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
HANDOFFD = REPO_ROOT / "bridge-handoffd.py"


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
    an HTTP reply, so the probe sees a reset/timeout (the non-hairpin symptom),
    while the OS reports the address as in use (EADDRINUSE) to the fallback.
    """
    srv = socket.socket(socket.AF_INET6 if ":" in bind else socket.AF_INET,
                        socket.SOCK_STREAM)
    # Deliberately NO SO_REUSEADDR: the fallback relies on a plain bind raising
    # EADDRINUSE while this socket is held, exactly as the production probe does.
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


def _run_probe(config: str, timeout: str) -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(HANDOFFD), "healthz",
         "--config", config, "--timeout", timeout],
        capture_output=True, text=True, timeout=60,
    )
    reason = (proc.stdout or "").strip().splitlines()
    word = reason[-1].strip() if reason else ""
    return proc.returncode, word


def run_healthz(config: str, bind: str, port: int, mode: str, timeout: str) -> int:
    stop = threading.Event()
    srv = None
    try:
        if mode == "held":
            srv = _hold_and_drop_server(bind, port, stop)
            # Give the accept thread a beat to be ready before probing.
            time.sleep(0.1)
        elif mode == "nothing":
            pass  # nothing listening
        else:
            print(f"ERR=unknown_mode:{mode}")
            return 2
        rc, word = _run_probe(config, timeout)
        print(f"RC={rc}")
        print(f"REASON={word}")
        return 0
    finally:
        stop.set()
        if srv is not None:
            try:
                srv.close()
            except OSError:
                pass


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: free-port | run-healthz <config> <bind> <port> <mode> <timeout>",
              file=sys.stderr)
        return 2
    scenario = argv[0]
    if scenario == "free-port":
        print(_free_port())
        return 0
    if scenario == "run-healthz":
        config, bind, port_s, mode, timeout = argv[1], argv[2], argv[3], argv[4], argv[5]
        return run_healthz(config, bind, int(port_s), mode, timeout)
    print(f"ERR=unknown_scenario:{scenario}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
