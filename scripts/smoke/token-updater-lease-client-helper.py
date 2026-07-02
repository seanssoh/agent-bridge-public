#!/usr/bin/env python3
"""Helper for scripts/smoke/token-updater-lease-client.sh (#21895 phase-1, sub-PR 2/4).

Kept tiny and heredoc-free (footgun #11): the smoke driver invokes discrete
verbs so no large Python body is fed to a subprocess over stdin. Each verb
exercises a Contract-A primitive DIRECTLY (imported from bridge-auth.py) so the
smoke pins the client/mapping/lease-state behavior without a live network.

Verbs:
  json-field <dotted.key>          read JSON from stdin, print the (dotted) field
  file-mode <path>                 print the octal mode bits (e.g. 600) of <path>
  map <email> <registry-json-path> print token_updater_map_account_to_local(...)
                                   as `status:local_token_id?:reason?`
  lease-state-roundtrip <path>     write a fixture lease-state via the sanctioned
                                   writer, read it back, print `OK:<mode>` on an
                                   exact round-trip else `MISMATCH`
  retry-after <value>              print _parse_retry_after({"Retry-After": value})
                                   ("None" when it degrades)
  client <verb> <fixture-dir>      run TokenUpdaterLeaseClient.<verb> against the
                                   fixture dir; print `status:http`
"""
from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
from pathlib import Path


def _load_bridge_auth():
    repo = Path(__file__).resolve().parent.parent.parent
    spec = importlib.util.spec_from_file_location("ba_probe", str(repo / "bridge-auth.py"))
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _get(payload: object, dotted: str) -> object:
    cur = payload
    for part in dotted.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
    return cur


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: token-updater-lease-client-helper.py <verb> [args...]", file=sys.stderr)
        return 2
    verb = sys.argv[1]

    if verb == "json-field":
        dotted = sys.argv[2]
        raw = sys.stdin.read()
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            print("")
            return 0
        value = _get(payload, dotted)
        if isinstance(value, bool):
            print("True" if value else "False")
        elif value is None:
            print("")
        else:
            print(value)
        return 0

    if verb == "file-mode":
        path = sys.argv[2]
        try:
            mode = stat.S_IMODE(os.stat(path).st_mode)
        except OSError:
            print("ABSENT")
            return 0
        print(oct(mode)[-3:])
        return 0

    module = _load_bridge_auth()

    if verb == "map":
        email = sys.argv[2]
        registry_path = sys.argv[3]
        registry = json.loads(Path(registry_path).read_text(encoding="utf-8"))
        result = module.token_updater_map_account_to_local(email, registry)
        print(
            f"{result.get('status')}:{result.get('local_token_id') or ''}:"
            f"{result.get('reason') or ''}"
        )
        return 0

    if verb == "lease-state-roundtrip":
        os.environ["BRIDGE_TOKEN_UPDATER_LEASE_STATE_FILE"] = sys.argv[2]
        fixture = {
            "service_token_id": "svc-rt",
            "account_email": "rt@example.com",
            "local_token_id": "tok-rt",
            "lease_expires_at": 1751000000,
            "last_heartbeat_at": 1750999000,
        }
        path, reason = module.write_token_updater_lease_state(fixture)
        if path is None:
            print(f"WRITE_FAILED:{reason}")
            return 0
        back = module.read_token_updater_lease_state()
        mode = oct(stat.S_IMODE(os.stat(path).st_mode))[-3:]
        print(f"OK:{mode}" if back == fixture else f"MISMATCH:{back}")
        return 0

    if verb == "retry-after":
        value = sys.argv[2]
        result = module._parse_retry_after({"Retry-After": value})
        print("None" if result is None else result)
        return 0

    if verb == "client":
        method = sys.argv[2]
        fixture_dir = sys.argv[3]
        os.environ["BRIDGE_TOKEN_UPDATER_LEASE_FIXTURE_DIR"] = fixture_dir
        client = module.TokenUpdaterLeaseClient(
            api_url="https://lease.example.com", api_key="fixture-key", server_id="srv-1"
        )
        if method == "checkout":
            result = client.checkout()
        elif method == "heartbeat":
            result = client.heartbeat("svc-1")
        elif method == "swap":
            result = client.swap("svc-old")
        elif method == "checkin":
            result = client.checkin("svc-1")
        else:
            print(f"unknown client method: {method}", file=sys.stderr)
            return 2
        print(f"{result.get('status')}:{result.get('http')}")
        return 0

    print(f"unknown verb: {verb}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
