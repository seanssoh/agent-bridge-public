#!/usr/bin/env python3
"""gateway-socket-connect-probe.py — defense-in-depth liveness check for
the queue gateway Unix-domain SEQPACKET socket. Returns 0 when a
listener accepts the connection, 1 otherwise (recycled pid + leftover
socket, or socket file `touch`ed by an unrelated tool).

Invocation contract:
    sys.argv[1] = path to the bound socket file.

Exit codes:
    0 — connect() succeeded; a listener is bound and accepting.
    1 — SOCK_SEQPACKET unavailable, missing path, or connect failed.

Side-effect-free: probe does not send a payload, so the listener does
not need to read or respond. settimeout(1.0) bounds the probe.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$socket_path" <<'PY' >/dev/null 2>&1` heredoc-stdin in
bridge_queue_gateway_socket_connect_probe. The status path runs on
every `daemon status` invocation and showed wedges on the operator
host under concurrent dispatch pressure; moved to a standalone file
invoked as `python3 gateway-socket-connect-probe.py <socket_path>`
to remove the heredoc-stdin path — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import socket
import sys


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    if not path:
        return 1
    sock_type = getattr(socket, "SOCK_SEQPACKET", None)
    if sock_type is None:
        return 1
    sock = socket.socket(socket.AF_UNIX, sock_type)
    try:
        sock.settimeout(1.0)
        sock.connect(path)
    except OSError:
        return 1
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
