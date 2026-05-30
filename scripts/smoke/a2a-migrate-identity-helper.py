#!/usr/bin/env python3
"""Helper for a2a-migrate-identity.sh — file-as-argv JSON probes.

This file exists so the smoke never uses `python3 - <<PY` heredoc-stdin in a
command substitution (C1 / footgun #11 — the Bash 5.3.9 read_comsub deadlock).
It is invoked as a real file with explicit argv:

    python3 a2a-migrate-identity-helper.py get   <config.json> <jsonpath>
    python3 a2a-migrate-identity-helper.py mode  <config.json>
    python3 a2a-migrate-identity-helper.py sha   <config.json>

`get` jsonpath grammar (minimal, no deps):
    listen.node_id
    listen.tailscale_name
    listen.address
    peer:<peer_id>.node_id            (peers[] entry matched by .id)
    peer:<peer_id>.tailscale_name
    peer:<peer_id>.address
    peer:<peer_id>.secret
    peer:<peer_id>.inbound_allowlist  (printed as comma-joined)
    peer:<peer_id>.caps.max_body_bytes
A missing key prints the literal "<MISSING>" (so the smoke can assert removal).
"""

from __future__ import annotations

import hashlib
import json
import sys

MISSING = "<MISSING>"


def _load(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _peer(cfg: dict, peer_id: str) -> dict:
    for peer in cfg.get("peers", []):
        if isinstance(peer, dict) and peer.get("id") == peer_id:
            return peer
    return {}


def _get(cfg: dict, jsonpath: str) -> str:
    if jsonpath.startswith("peer:"):
        rest = jsonpath[len("peer:"):]
        peer_id, _, field = rest.partition(".")
        node = _peer(cfg, peer_id)
    elif jsonpath.startswith("listen."):
        node = cfg.get("listen", {})
        field = jsonpath[len("listen."):]
    else:
        node = cfg
        field = jsonpath
    if not isinstance(node, dict):
        return MISSING
    # Support a single nested level (caps.max_body_bytes).
    head, _, tail = field.partition(".")
    if tail:
        sub = node.get(head, {})
        if not isinstance(sub, dict) or tail not in sub:
            return MISSING
        return str(sub[tail])
    if head not in node:
        return MISSING
    val = node[head]
    if isinstance(val, list):
        return ",".join(str(x) for x in val)
    return str(val)


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: helper <get|mode|sha> <config.json> [jsonpath]", file=sys.stderr)
        return 2
    op = argv[1]
    path = argv[2]
    if op == "get":
        if len(argv) < 4:
            print("get needs a jsonpath", file=sys.stderr)
            return 2
        print(_get(_load(path), argv[3]))
        return 0
    if op == "mode":
        import os
        print(f"{os.stat(path).st_mode & 0o777:04o}")
        return 0
    if op == "sha":
        with open(path, "rb") as fh:
            print(hashlib.sha256(fh.read()).hexdigest())
        return 0
    print(f"unknown op: {op}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
