#!/usr/bin/env python3
"""Helper for scripts/smoke/a2a-ip-change-announce.sh — P-self-heal-3
(design §9.6) signed peer-identity-update control message.

Kept as a standalone FILE (file-as-argv, never heredoc-stdin) per footgun
#11 + the lint-heredoc-ban ratchet. Two roles:

  free-port
        Print an unused TCP port (for the loopback receiver).

  wait-port <port>
        Exit 0 once <port> accepts a TCP connect, else exit 1.

  post <base_url> <peer_id> <secret> <case>
        Sign + POST a peer-identity-update to the LIVE receiver and print
        `STATUS=<code>` plus the JSON body. `<case>` selects the body /
        tamper shape:
          ok            valid claim that the receiver's mock corroborates
          spoof         claim a DIFFERENT (real-but-not-this-peer) identity
                        the receiver's status does NOT corroborate for this
                        peer (the anti-spoof case) -> 409
          badhmac       sign with the wrong secret -> 401
          replay        re-send the SAME signed message (same message_id +
                        body) -> idempotent 200 duplicate
          emptyid       VALID signature but an EMPTY X-AGB-Message-Id header
                        (and empty id baked into the canonical string so the
                        HMAC still verifies) -> must be REJECTED (400) BEFORE
                        any dedupe/mutation (#1406 codex r1 SECURITY: an empty
                        id previously skipped dedupe AND let the bridge_id
                        corroboration be bypassed).
          bridgemismatch VALID signature, NON-empty id, but the signed body
                        claims a bridge_id != the authenticated X-AGB-Peer
                        (announcing about a DIFFERENT peer) -> must be REJECTED
                        (422) unconditionally (#1406 codex r1 SECURITY: the
                        body bridge_id MUST always equal the authenticated
                        peer; a peer may only announce about ITSELF).
        The message_id is deterministic per (peer_id, case) so `replay`
        reuses the `ok` id.

The receiver is driven through its REAL do_POST stack (HMAC, remote_addr,
dedupe, skew, corroborate, apply) — this helper only crafts the wire bytes,
so the smoke asserts the genuine fail-closed behavior.
"""
from __future__ import annotations

import hashlib
import hmac
import importlib.util
import json
import socket
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import bridge_a2a_common as a2a  # noqa: E402

IDENTITY_UPDATE_PATH = a2a.IDENTITY_UPDATE_PATH
PROTOCOL = a2a.IDENTITY_UPDATE_PROTOCOL_VERSION


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _wait_port(port: int) -> int:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return 0
    except OSError:
        return 1


def _sign(secret: str, canonical: str) -> str:
    digest = hmac.new(secret.encode("utf-8"), canonical.encode("utf-8"),
                      hashlib.sha256)
    return "v1=" + digest.hexdigest()


def _post(base_url: str, peer_id: str, secret: str, case: str) -> int:
    # Deterministic message_id so `replay` reuses the `ok` id (and a
    # distinct id per other case so dedupe never cross-talks).
    # `emptyid` deliberately sends an EMPTY message_id (header + canonical) to
    # prove the receiver rejects it BEFORE dedupe/mutation (#1406 SECURITY).
    if case == "emptyid":
        message_id = ""
    else:
        mid_case = "ok" if case == "replay" else case
        message_id = f"{peer_id}:smoke-identity-{mid_case}"

    # Body: the sender's CLAIM about its own identity. For `ok`/`replay` the
    # claim names the node the receiver's mock corroborates for this peer
    # (StableID peerStableID999 / cm-prod-... / 127.0.0.1). For `spoof` the
    # claim names a DIFFERENT real node (otherStableID / other-host) that the
    # receiver's status has, but which is NOT this peer's paired node — the
    # corroboration same-node anchor must reject it. For `bridgemismatch` the
    # claim names a DIFFERENT peer's bridge_id (cross-peer announce) — must be
    # rejected unconditionally (#1406 SECURITY).
    if case == "spoof":
        body = {
            "protocol": a2a.IDENTITY_UPDATE_ENVELOPE_PROTOCOL,
            "bridge_id": peer_id,
            "node_id": "otherStableID",
            "tailscale_name": "other-host",
            "tailscale_ip": "127.0.0.9",
        }
    elif case == "bridgemismatch":
        body = {
            "protocol": a2a.IDENTITY_UPDATE_ENVELOPE_PROTOCOL,
            # The signed body claims a DIFFERENT peer than the authenticated
            # X-AGB-Peer — a cross-peer announce the receiver must refuse.
            "bridge_id": f"{peer_id}-impersonated-other",
            "node_id": "peerStableID999",
            "tailscale_name": "cm-prod-agentworkflow-vm01",
            "tailscale_ip": "127.0.0.1",
        }
    else:
        body = {
            "protocol": a2a.IDENTITY_UPDATE_ENVELOPE_PROTOCOL,
            "bridge_id": peer_id,
            "node_id": "peerStableID999",
            "tailscale_name": "cm-prod-agentworkflow-vm01",
            "tailscale_ip": "127.0.0.1",
        }
    body_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
    body_hash = hashlib.sha256(body_bytes).hexdigest()
    timestamp = str(int(time.time()))
    path = IDENTITY_UPDATE_PATH
    canonical = "\n".join(["POST", path, peer_id, message_id, timestamp,
                           body_hash])
    sign_secret = "wrong-secret-deadbeef" if case == "badhmac" else secret
    signature = _sign(sign_secret, canonical)

    url = base_url + path
    req = urllib.request.Request(url, data=body_bytes, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-AGB-Protocol", PROTOCOL)
    req.add_header("X-AGB-Peer", peer_id)
    req.add_header("X-AGB-Message-Id", message_id)
    req.add_header("X-AGB-Timestamp", timestamp)
    req.add_header("X-AGB-Body-SHA256", body_hash)
    req.add_header("X-AGB-Signature", signature)
    try:
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            print(f"STATUS={resp.status}")
            print(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        print(f"STATUS={exc.code}")
        try:
            print((exc.read() or b"").decode("utf-8", "replace"))
        except Exception:  # noqa: BLE001
            print("")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: helper free-port|wait-port|post ...", file=sys.stderr)
        return 2
    cmd = argv[0]
    if cmd == "free-port":
        print(_free_port())
        return 0
    if cmd == "wait-port":
        return _wait_port(int(argv[1]))
    if cmd == "post":
        return _post(argv[1], argv[2], argv[3], argv[4])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
