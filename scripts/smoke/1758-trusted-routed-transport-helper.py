#!/usr/bin/env python3
"""Helper for the 1758-trusted-routed-transport smoke.

Kept as a file-as-argv sidecar (not a heredoc fed into `python3 -`) so the
smoke shell never trips the Bash 5.3.9 heredoc-stdin deadlock (footgun #11).
Imports bridge_a2a_common from the repo root so the smoke exercises the real
HMAC scheme + the real #1758 trusted-routed transport seam.

Scenarios
  free-port                       print a free loopback TCP port
  wait-port <port>                exit 0 once <port> accepts (else 1)
  ok <url> <peer> <secret>        signed enqueue happy path -> STATUS=200
  auth-fail <url> <peer> <secret> bad HMAC signature       -> STATUS=401
  room-scoped <url> <peer> <secret>
                                  room-scoped enqueue (no rooms.db) -> 403,
                                  proving room_scoped_check still gates the
                                  trusted-routed transport (fail-closed).
  source-select                   assert select_source_address_for_transport
                                  returns the mesh listen.address for a
                                  warp-mesh peer and None (OS-routed) for a
                                  trusted-routed peer (#1758 sender symmetry).
  source-bound-egress <port>      drive a real POST through source_bound_opener
                                  to a loopback HTTP echo server: the
                                  mesh-source case binds 127.0.0.1 (the chosen
                                  source); the routed (None) case is OS-routed.
"""

from __future__ import annotations

import json
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import bridge_a2a_common as a2a  # noqa: E402


def post(
    *,
    url: str,
    path: str,
    peer_id: str,
    secret: str,
    envelope: dict,
    bad_signature: bool = False,
) -> tuple[int, str]:
    body = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
    message_id = envelope["message_id"]
    timestamp = str(a2a.now_ts())
    body_hash = a2a.body_sha256(body)
    canonical = a2a.canonical_string("POST", path, peer_id, message_id,
                                     timestamp, body_hash)
    signature = a2a.sign(secret, canonical)
    if bad_signature:
        signature = "v1=" + "0" * 64

    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-AGB-Protocol", a2a.PROTOCOL_VERSION)
    req.add_header("X-AGB-Peer", peer_id)
    req.add_header("X-AGB-Message-Id", message_id)
    req.add_header("X-AGB-Timestamp", timestamp)
    req.add_header("X-AGB-Body-SHA256", body_hash)
    req.add_header("X-AGB-Signature", signature)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, (exc.read() or b"").decode("utf-8", "replace")
    except urllib.error.URLError as exc:
        return -1, str(exc)


def envelope(message_id: str, target: str, title: str, body: str,
             *, room_id: str = "", room_epoch=None) -> dict:
    return a2a.build_envelope(
        message_id=message_id,
        sender_bridge="bridge-a",
        sender_agent="senderX",
        target_agent=target,
        priority="normal",
        title=title,
        body=body,
        reply_peer="bridge-a",
        reply_agent="senderX",
        room_id=room_id,
        room_epoch=room_epoch,
    )


def _free_port() -> int:
    import socket as _s
    sock = _s.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def _port_open(port: int) -> bool:
    import socket as _s
    sock = _s.socket()
    sock.settimeout(0.5)
    try:
        sock.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def _source_select() -> int:
    """Assert the #1758 sender source-symmetry selection per transport.

    A warp-mesh peer must egress from this node's OWN Mesh listen.address; a
    trusted-routed (and tailscale) peer must get None so the OS routing table
    picks the reachable egress source for the destination.
    """
    cfg = {"listen": {"address": "10.128.0.25", "port": 8787}}
    peer = {"address": "10.21.2.4"}
    mesh = a2a.select_source_address_for_transport(
        a2a.TRANSPORT_CLOUDFLARE_WARP_MESH, cfg, peer)
    routed = a2a.select_source_address_for_transport(
        a2a.TRANSPORT_TRUSTED_ROUTED, cfg, peer)
    tail = a2a.select_source_address_for_transport(
        a2a.TRANSPORT_TAILSCALE, cfg, peer)
    # A warp-mesh node with no usable Mesh listen.address falls back to None
    # (OS-routed) rather than guessing a source.
    mesh_nolisten = a2a.select_source_address_for_transport(
        a2a.TRANSPORT_CLOUDFLARE_WARP_MESH, {"listen": {}}, peer)
    print(f"MESH_SOURCE={mesh}")
    print(f"ROUTED_SOURCE={routed}")
    print(f"TAILSCALE_SOURCE={tail}")
    print(f"MESH_NOLISTEN_SOURCE={mesh_nolisten}")
    return 0


def _source_bound_egress(port: int) -> int:
    """Drive a real POST through source_bound_opener to a loopback echo server.

    The echo server replies with the client (source) IP it observed. We assert
    the mesh-source case binds the chosen 127.0.0.1 source and the routed
    (None) case still delivers (OS-routed). Loopback is the only universally
    available local source in CI; on a host with real Mesh + LAN interfaces the
    same code binds the Mesh IP vs lets the OS pick the LAN IP.
    """

    class _Echo(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            length = int(self.headers.get("Content-Length", "0"))
            self.rfile.read(length)
            client_ip = self.client_address[0]
            payload = json.dumps({"src": client_ip}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *args):  # noqa: ANN002 - silence
            return

    srv = HTTPServer(("127.0.0.1", port), _Echo)
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{port}/enqueue"

        # mesh source: bind 127.0.0.1 (stands in for the Mesh listen.address).
        opener = a2a.source_bound_opener("127.0.0.1")
        req = urllib.request.Request(url, data=b"{}", method="POST")
        with opener.open(req, timeout=10) as resp:
            bound = json.loads(resp.read().decode("utf-8"))
        print(f"BOUND_STATUS={resp.status} BOUND_SRC={bound['src']}")

        # routed source: None -> default opener (OS-routed), still delivers.
        opener2 = a2a.source_bound_opener(None)
        req2 = urllib.request.Request(url, data=b"{}", method="POST")
        with opener2.open(req2, timeout=10) as resp2:
            routed = json.loads(resp2.read().decode("utf-8"))
        print(f"ROUTED_STATUS={resp2.status} ROUTED_SRC={routed['src']}")
    finally:
        srv.shutdown()
        srv.server_close()
    return 0


def main(argv: list[str]) -> int:
    scenario = argv[0]
    if scenario == "free-port":
        print(_free_port())
        return 0
    if scenario == "wait-port":
        return 0 if _port_open(int(argv[1])) else 1
    if scenario == "source-select":
        return _source_select()
    if scenario == "source-bound-egress":
        return _source_bound_egress(int(argv[1]))

    base_url = argv[1]
    peer_id = argv[2]
    secret = argv[3]
    path = "/enqueue"
    url = base_url.rstrip("/") + path

    if scenario == "ok":
        env = envelope("bridge-a:tr-ok-1", "reviewer",
                       "trusted routed ok", "the body")
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                            envelope=env)
    elif scenario == "auth-fail":
        env = envelope("bridge-a:tr-auth-fail-1", "reviewer",
                       "trusted routed auth fail", "x")
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                            envelope=env, bad_signature=True)
    elif scenario == "room-scoped":
        # A room-scoped envelope must be gated by room_scoped_check exactly as
        # on the other transports. With no rooms.db present the gate fails
        # CLOSED (no_rooms_db) -> 403. This proves room-scoped delivery routes
        # through the SAME room gate over the trusted-routed transport (the
        # transport is additive; it does not bypass the room boundary).
        env = envelope("bridge-a:tr-room-1", "reviewer",
                       "trusted routed room scoped", "the body",
                       room_id="room-smoke", room_epoch=0)
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                            envelope=env)
    else:
        print(f"unknown scenario: {scenario}", file=sys.stderr)
        return 2

    print(f"STATUS={status} BODY={text}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
