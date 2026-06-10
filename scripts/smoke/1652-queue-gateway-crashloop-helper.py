#!/usr/bin/env python3
"""1652-queue-gateway-crashloop-helper.py — driver for the #1652 queue-gateway
socket listener crash-loop regression smoke.

Loaded file-as-argv (footgun #11: NO heredoc-stdin to a Python subprocess). The
smoke's shell side invokes `python3 <helper> <subcommand> ...`; this file holds
every Python snippet that used to live as `python3 - <<'PY'` heredoc-stdin in
the smoke, which tripped the lint-heredoc-ban C1 (capture-deadlock) ratchet.

Every assertion drives the REAL production code in bridge-queue-gateway.py via
importlib — nothing is re-implemented here.

Subcommands:
  bug2-missing-socket-degrades <repo_root>
      _set_socket_group_mode / _refresh_socket_perms on a MISSING socket path
      must return False (degrade), not raise FileNotFoundError into the accept
      loop. Prints `ok-missing-socket-degrades` on pass.

  bug3-probe-close-quiet <repo_root>
      An empty connect-probe recv must raise the distinct _ProbeClose, NOT a
      malformed-payload ValueError (and _ProbeClose must not subclass
      ValueError, or it would re-enter the invalid_payload deny path). Prints
      `ok-empty-recv-is-probeclose` on pass.

  bind-and-close <socket_path>
      Bind a SOCK_SEQPACKET socket at <socket_path> then close it, leaving an
      UNBOUND socket file on disk (no listener). Used by the bug1-inverse
      "genuinely-dead socket is still cleaned" case.

  live-listener <socket_path> [deadline_seconds]
      Bind + listen + accept-loop a SOCK_SEQPACKET listener at <socket_path>,
      serving until killed or the deadline (default 30s). accept() flaps on a
      1.0s timeout — exactly the window that produced the transient-probe miss
      in the bug. Run as a background process by the bug1 "live socket kept"
      case. Prints nothing on the happy path (the shell side probes the
      socket); errors go to stderr.

On a contract violation the *assertion* subcommands print a `FAIL ...` line and
exit 0 (so the shell `smoke_assert_contains` reports the mismatch with full
context); a usage error exits 2.
"""

import importlib.util
import os
import socket
import sys
import time
from pathlib import Path


def _load_gateway(repo_root: str):
    """Import bridge-queue-gateway.py as a module from the source checkout."""
    repo = Path(repo_root)
    spec = importlib.util.spec_from_file_location(
        "bqg", repo / "bridge-queue-gateway.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, repo


def cmd_bug2_missing_socket_degrades(argv) -> int:
    if len(argv) < 3:
        print("usage: helper bug2-missing-socket-degrades <repo_root>", file=sys.stderr)
        return 2
    mod, repo = _load_gateway(argv[2])

    missing = repo / "does-not-exist" / "queue-gateway.sock"

    # _set_socket_group_mode on a missing path must return False, not raise.
    # live=False so a missing ab-shared group degrades to the 0600 branch
    # rather than SystemExit; either branch must still not raise on a missing
    # path.
    try:
        rv = mod._set_socket_group_mode(missing, live=False)
    except FileNotFoundError:
        print("FAIL: _set_socket_group_mode raised FileNotFoundError")
        return 0
    if rv is not False:
        print(f"FAIL: _set_socket_group_mode returned {rv!r}, expected False")
        return 0

    # _refresh_socket_perms must propagate the False (degrade) without raising.
    try:
        rv2 = mod._refresh_socket_perms(missing, {}, repo, live=False)
    except FileNotFoundError:
        print("FAIL: _refresh_socket_perms raised FileNotFoundError")
        return 0
    if rv2 is not False:
        print(f"FAIL: _refresh_socket_perms returned {rv2!r}, expected False")
        return 0

    print("ok-missing-socket-degrades")
    return 0


def cmd_bug3_probe_close_quiet(argv) -> int:
    if len(argv) < 3:
        print("usage: helper bug3-probe-close-quiet <repo_root>", file=sys.stderr)
        return 2
    mod, _repo = _load_gateway(argv[2])

    if issubclass(mod._ProbeClose, ValueError):
        print("FAIL: _ProbeClose must not subclass ValueError (would re-enter invalid_payload)")
        return 0

    # Drive _recv_json with a socketpair where the writer closes without
    # sending anything — the reader's recv() returns b'' -> _ProbeClose.
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    b.close()
    try:
        mod._recv_json(a)
    except mod._ProbeClose:
        print("ok-empty-recv-is-probeclose")
    except ValueError as exc:
        print(f"FAIL: empty recv raised ValueError {exc!r}, expected _ProbeClose")
    finally:
        a.close()
    return 0


def cmd_bind_and_close(argv) -> int:
    if len(argv) < 3:
        print("usage: helper bind-and-close <socket_path>", file=sys.stderr)
        return 2
    path = argv[2]
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    s.bind(path)
    s.close()
    return 0


def cmd_live_listener(argv) -> int:
    if len(argv) < 3:
        print("usage: helper live-listener <socket_path> [deadline_seconds]", file=sys.stderr)
        return 2
    path = argv[2]
    deadline_seconds = float(argv[3]) if len(argv) > 3 else 30.0
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    s.bind(path)
    s.listen(64)
    s.settimeout(1.0)
    # Serve until the parent kills us. accept() flaps on the 1.0s timeout, which
    # is exactly the window that produced the transient-probe miss in the bug.
    deadline = time.monotonic() + deadline_seconds
    while time.monotonic() < deadline:
        try:
            conn, _ = s.accept()
        except (TimeoutError, socket.timeout):
            continue
        except OSError:
            break
        try:
            conn.close()
        except OSError:
            pass
    return 0


_DISPATCH = {
    "bug2-missing-socket-degrades": cmd_bug2_missing_socket_degrades,
    "bug3-probe-close-quiet": cmd_bug3_probe_close_quiet,
    "bind-and-close": cmd_bind_and_close,
    "live-listener": cmd_live_listener,
}


def main(argv) -> int:
    if len(argv) < 2:
        print("usage: helper <subcommand> ...", file=sys.stderr)
        return 2
    fn = _DISPATCH.get(argv[1])
    if fn is None:
        print(f"FAIL unknown subcommand: {argv[1]}", file=sys.stderr)
        return 2
    return fn(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
