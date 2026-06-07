#!/usr/bin/env python3
"""Helper for 1629-healthz-not-semaphore-gated.sh (#1629).

File-as-argv sidecar (not a heredoc into `python3 -`) so the smoke shell never
trips the Bash 5.3.9 heredoc-stdin deadlock (footgun #11). Drives a RUNNING A2A
receiver to prove the liveness probe is exempt from the request-concurrency
semaphore.

Subcommands (each prints one terse, assert-friendly line and exits 0):

  saturate-then-probe <host> <port> <max_concurrent> <hold_seconds>
      Open <max_concurrent> "slow" connections that send a PARTIAL request line
      (no terminating newline) so each handler thread blocks reading the request
      line until the receiver's request deadline — holding ALL semaphore slots.
      THEN, while saturated, fire two probes from fresh connections:
        * GET <healthz>   -> must be 200 (the #1629 exemption)
        * a real GET /    -> must be 503 (proves the semaphore really IS full,
                             i.e. the held connections are occupying every slot)
      Prints: HEALTHZ=<code> REAL=<code> HELD=<n>

  probe-healthz <host> <port> [path]
      Single GET on the liveness path against an UN-saturated receiver.
      Prints: HEALTHZ=<code>

  idle-connect-then-probe <host> <port> [path]
      Open ONE connection and send NO bytes (an idle/slow-connect peer that
      withholds its request line), then time a GET <healthz> from a fresh
      connection. The classification peek runs on the SINGLE-THREADED accept
      loop, so a blocking peek would stall accepting the probe for the whole
      request timeout. Asserts the probe is still answered FAST.
      Prints: HEALTHZ=<code> ELAPSED_MS=<n>

  healthz-slow-flood <host> <port> <count> <healthz_bound> [path]
      Open <count> healthz-SHAPED slow connections — each sends the request line
      `GET <healthz> HTTP/1.1\r\n` then stalls before the header terminator. The
      exempt probe is gated on its OWN small bounded semaphore (<healthz_bound>),
      so the first <healthz_bound> are accepted into worker threads (and hang in
      header parsing) while the rest are REJECTED FAST (503) without spawning a
      thread. Counts the 503s among the overflow connections.
      Prints: REJECTED=<n> OVERFLOW=<count - healthz_bound>

The held/idle connections are closed before returning so the receiver is clean.
"""

from __future__ import annotations

import socket
import sys
import time

HEALTHZ_PATH = "/healthz"
CONNECT_TIMEOUT = 5.0
PROBE_TIMEOUT = 5.0


def _raw_get(host: str, port: int, path: str, timeout: float) -> int:
    """Send a complete `GET <path>` request on a fresh connection; return the
    HTTP status code, or -1 on any transport error."""
    sock = socket.create_connection((host, port), timeout=timeout)
    try:
        sock.settimeout(timeout)
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Connection: close\r\n"
            "\r\n"
        ).encode("ascii")
        sock.sendall(req)
        chunks: list[bytes] = []
        while True:
            try:
                data = sock.recv(4096)
            except socket.timeout:
                break
            if not data:
                break
            chunks.append(data)
            if b"\r\n\r\n" in b"".join(chunks):
                break
        raw = b"".join(chunks)
        if not raw.startswith(b"HTTP/"):
            return -1
        try:
            return int(raw.split(b" ", 2)[1])
        except (IndexError, ValueError):
            return -1
    finally:
        try:
            sock.close()
        except OSError:
            pass


def _open_slow_connection(host: str, port: int) -> socket.socket:
    """Open a connection and send a PARTIAL request line (no newline). The
    receiver's handler thread blocks reading the request line until its request
    deadline, holding one semaphore slot for the duration."""
    sock = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    # A partial request line with NO terminating newline. handle_one_request's
    # readline keeps reading until the request deadline -> the handler thread
    # (and its semaphore slot) is held without ever completing a request.
    sock.sendall(b"GET /enqueue-slow-no-newline")
    return sock


def cmd_saturate_then_probe(argv: list[str]) -> int:
    host = argv[0]
    port = int(argv[1])
    max_concurrent = int(argv[2])
    hold_seconds = float(argv[3])
    healthz_path = argv[4] if len(argv) > 4 else HEALTHZ_PATH

    held: list[socket.socket] = []
    try:
        for _ in range(max_concurrent):
            try:
                held.append(_open_slow_connection(host, port))
            except OSError:
                break
        # Give the receiver a beat to accept + dispatch all held connections so
        # every slot is actually acquired before we probe.
        deadline = time.monotonic() + min(hold_seconds, 3.0)
        time.sleep(0.4)
        # Re-assert the hold window has not elapsed (the slow connections must
        # still be occupying slots when we probe).
        if time.monotonic() >= deadline:
            pass  # best-effort; the probes below are the real assertions

        healthz_code = _raw_get(host, port, healthz_path, PROBE_TIMEOUT)
        real_code = _raw_get(host, port, "/", PROBE_TIMEOUT)
        print(f"HEALTHZ={healthz_code} REAL={real_code} HELD={len(held)}")
    finally:
        for sock in held:
            try:
                sock.close()
            except OSError:
                pass
    return 0


def cmd_probe_healthz(argv: list[str]) -> int:
    host = argv[0]
    port = int(argv[1])
    healthz_path = argv[2] if len(argv) > 2 else HEALTHZ_PATH
    print(f"HEALTHZ={_raw_get(host, port, healthz_path, PROBE_TIMEOUT)}")
    return 0


def cmd_idle_connect_then_probe(argv: list[str]) -> int:
    host = argv[0]
    port = int(argv[1])
    healthz_path = argv[2] if len(argv) > 2 else HEALTHZ_PATH

    # Open a connection and send NOTHING — a peer that withholds its request
    # line. With a BLOCKING classification peek on the accept loop this would
    # stall accepting the probe below for the whole request timeout.
    idle = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    try:
        start = time.monotonic()
        code = _raw_get(host, port, healthz_path, PROBE_TIMEOUT)
        elapsed_ms = int((time.monotonic() - start) * 1000)
        print(f"HEALTHZ={code} ELAPSED_MS={elapsed_ms}")
    finally:
        try:
            idle.close()
        except OSError:
            pass
    return 0


def _open_healthz_shaped_slow(host: str, port: int, healthz_path: str) -> socket.socket:
    """Open a connection, send a complete healthz request LINE, then stall before
    the header terminator. Classifies as a healthz probe (request line buffered)
    but never completes header parsing — the resource the healthz bound caps."""
    sock = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    sock.sendall(f"GET {healthz_path} HTTP/1.1\r\n".encode("ascii"))
    return sock


def _try_read_status(sock: socket.socket, timeout: float) -> int:
    """Read a status code if the server already replied (e.g. a fast 503 from the
    accept-time bound), else -1 if nothing arrived within the timeout."""
    sock.settimeout(timeout)
    try:
        data = sock.recv(64)
    except (socket.timeout, OSError):
        return -1
    if not data or not data.startswith(b"HTTP/"):
        return -1
    try:
        return int(data.split(b" ", 2)[1])
    except (IndexError, ValueError):
        return -1


def cmd_healthz_slow_flood(argv: list[str]) -> int:
    host = argv[0]
    port = int(argv[1])
    count = int(argv[2])
    bound = int(argv[3])
    healthz_path = argv[4] if len(argv) > 4 else HEALTHZ_PATH

    socks: list[socket.socket] = []
    try:
        for _ in range(count):
            try:
                socks.append(_open_healthz_shaped_slow(host, port, healthz_path))
            except OSError:
                break
        # Let the accept loop process all of them: the first <bound> acquire the
        # healthz semaphore and hang in header parsing; the overflow get a fast
        # 503 at accept time.
        time.sleep(0.6)
        # Count fast 503s among the OVERFLOW connections (those opened after the
        # bound was reached). The first <bound> are hung (no reply yet).
        rejected = 0
        for sock in socks[bound:]:
            if _try_read_status(sock, 0.3) == 503:
                rejected += 1
        print(f"REJECTED={rejected} OVERFLOW={max(0, count - bound)}")
    finally:
        for sock in socks:
            try:
                sock.close()
            except OSError:
                pass
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: <subcommand> ...", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "saturate-then-probe":
        return cmd_saturate_then_probe(rest)
    if cmd == "probe-healthz":
        return cmd_probe_healthz(rest)
    if cmd == "idle-connect-then-probe":
        return cmd_idle_connect_then_probe(rest)
    if cmd == "healthz-slow-flood":
        return cmd_healthz_slow_flood(rest)
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
