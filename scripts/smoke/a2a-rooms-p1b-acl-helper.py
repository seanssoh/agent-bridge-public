#!/usr/bin/env python3
"""Helper for the a2a-rooms-p1b-acl smoke (internal-queue rooms ACL).

File-as-argv sidecar (NOT a heredoc into `python3 -`) so the smoke shell never
trips the Bash 5.3.9 heredoc-stdin deadlock (footgun #11). Imports the real
rooms / queue-gateway modules from the repo root so the smoke exercises the
canonical decision function and the gateway authorize_and_rewrite gate.

Subcommands (argv[1]):
  gateway-authz <peer> <to> [--from <x>]
      Run bridge-queue-gateway.authorize_and_rewrite() for a `create --to <to>`
      with peer_agent=<peer> (the SO_PEERCRED OS actor). Prints one line:
        ok=<0|1> reason=<code> from=<rewritten --from value or ->
      This is the PRIMARY iso-v2 gate (peer_agent is un-spoofable; a client
      --from in the argv is irrelevant — proves the spoof rejection).

  decision <db> <mode> <regime> <actor> <target>
      Call rooms.acl_create_decision() directly and print:
        outcome=<allow|deny|advisory> reason=<code>
      <regime> is one of: iso | controller | shared | unresolved.

  json-field <key> <json>            print a top-level field from JSON
  members-csv <show_or_adopt_json>   members as a comma-joined agent list
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import bridge_rooms_common as rooms  # noqa: E402


def _load_gateway():
    path = REPO_ROOT / "bridge-queue-gateway.py"
    spec = importlib.util.spec_from_file_location("bridge_queue_gateway", str(path))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_REGIME = {
    "iso": rooms.ACTOR_ISO_ENFORCED,
    "controller": rooms.ACTOR_CONTROLLER,
    "shared": rooms.ACTOR_SHARED_ADVISORY,
    "unresolved": rooms.ACTOR_UNRESOLVED,
}


def cmd_gateway_authz(argv: list[str]) -> int:
    # gateway-authz <peer> <to> [--from <x>] [--title T] [--body B]
    peer = argv[0]
    to = argv[1]
    spoof_from = None
    rest = argv[2:]
    i = 0
    while i < len(rest):
        if rest[i] == "--from" and i + 1 < len(rest):
            spoof_from = rest[i + 1]
            i += 2
            continue
        i += 1
    gw = _load_gateway()
    home = os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge"))  # noqa: iso-helper-boundary — test-only env read (smoke runner is the controller)
    create_argv = ["create", "--to", to, "--title", "t", "--body", "b"]
    if spoof_from is not None:
        create_argv += ["--from", spoof_from]
    ok, reason, rewritten = gw.authorize_and_rewrite(home, peer, create_argv)
    from_val = "-"
    if "--from" in rewritten:
        idx = rewritten.index("--from")
        if idx + 1 < len(rewritten):
            from_val = rewritten[idx + 1]
    print(f"ok={1 if ok else 0} reason={reason} from={from_val}")
    return 0


def cmd_decision(argv: list[str]) -> int:
    # decision <db> <mode> <regime> <actor> <target>
    db, mode, regime_key, actor, target = argv[0], argv[1], argv[2], argv[3], argv[4]
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary — test-only env set (smoke pins the isolated rooms.db)
    regime = _REGIME[regime_key]
    dec = rooms.acl_create_decision(
        mode=mode, regime=regime, actor=actor, target=target, node="",
    )
    print(f"outcome={dec.outcome} reason={dec.reason}")
    return 0


def cmd_json_field(key: str, blob: str) -> int:
    val = json.loads(blob).get(key)
    if val is None:
        return 1
    print(val)
    return 0


def cmd_members_csv(blob: str) -> int:
    members = json.loads(blob).get("members", [])
    print(",".join(m.get("agent", "") for m in members))
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: a2a-rooms-p1b-acl-helper.py <subcommand> ...", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "gateway-authz":
        return cmd_gateway_authz(rest)
    if cmd == "decision":
        return cmd_decision(rest)
    if cmd == "json-field":
        return cmd_json_field(rest[0], rest[1])
    if cmd == "members-csv":
        return cmd_members_csv(rest[0])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
