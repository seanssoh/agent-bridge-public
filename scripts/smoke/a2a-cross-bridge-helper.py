#!/usr/bin/env python3
"""Helper for the a2a-cross-bridge smoke — builds + sends signed POSTs.

Kept as a file-as-argv sidecar (not a heredoc fed into python3 -) so the
smoke shell never trips the Bash 5.3.9 heredoc-stdin deadlock (footgun
#11). Imports bridge_a2a_common from the repo root for the canonical
HMAC scheme so the smoke exercises the real signing code.
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
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
    sign_secret: str | None = None,
    bad_signature: bool = False,
    timestamp_override: str | None = None,
) -> tuple[int, str]:
    """Send one signed enqueue POST. Returns (status, body_text)."""
    body = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
    message_id = envelope["message_id"]
    timestamp = timestamp_override or str(a2a.now_ts())
    body_hash = a2a.body_sha256(body)
    canonical = a2a.canonical_string("POST", path, peer_id, message_id,
                                     timestamp, body_hash)
    key = sign_secret if sign_secret is not None else secret
    signature = a2a.sign(key, canonical)
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


def envelope(message_id: str, target: str, title: str, body: str) -> dict:
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


def main(argv: list[str]) -> int:
    """argv: <scenario> <base_url> <peer_id> <secret> [extra...]

    Emits a single line: `STATUS=<code> BODY=<json-or-text>` so the shell
    can assert on it.

    Two utility scenarios (no network enqueue) support the smoke harness:
      free-port            print a free loopback TCP port
      wait-port <port>     exit 0 once <port> accepts connections (else 1)
    """
    scenario = argv[0]

    if scenario == "free-port":
        print(_free_port())
        return 0
    if scenario == "wait-port":
        return 0 if _port_open(int(argv[1])) else 1

    base_url = argv[1]
    peer_id = argv[2]
    secret = argv[3]
    path = "/enqueue"
    url = base_url.rstrip("/") + path

    if scenario == "auth-fail":
        env = envelope("bridge-a:auth-fail-1", "reviewer", "auth fail", "x")
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                             envelope=env, bad_signature=True)
    elif scenario == "allowlist-fail":
        env = envelope("bridge-a:allowlist-1", "not-allowed", "blocked", "x")
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                             envelope=env)
    elif scenario == "ok":
        env = envelope("bridge-a:ok-1", "reviewer", "a2a smoke ok", "the body")
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                             envelope=env)
    elif scenario == "dup-same":
        env = envelope("bridge-a:dup-1", "reviewer", "dup same", "same body")
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                             envelope=env)
    elif scenario == "dup-conflict":
        # Same message_id as dup-same, different body → 409 expected.
        env = envelope("bridge-a:dup-1", "reviewer", "dup conflict",
                       "DIFFERENT body")
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                             envelope=env)
    elif scenario == "oversize":
        big = "x" * (300 * 1024)
        env = envelope("bridge-a:oversize-1", "reviewer", "too big", big)
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                             envelope=env)
    elif scenario == "skew":
        env = envelope("bridge-a:skew-1", "reviewer", "stale", "x")
        status, text = post(url=url, path=path, peer_id=peer_id, secret=secret,
                             envelope=env, timestamp_override="100")
    else:
        print(f"unknown scenario: {scenario}", file=sys.stderr)
        return 2

    print(f"STATUS={status} BODY={text}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
