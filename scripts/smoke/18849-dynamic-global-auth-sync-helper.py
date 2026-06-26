#!/usr/bin/env python3
"""Helper for scripts/smoke/18849-dynamic-global-auth-sync.sh (#18849 Part 1).

JSON seed/assert helpers kept out of the bash driver so the credential-shaped
keys (claudeAiOauth / accessToken / refreshToken) live in one place and the
smoke driver stays heredoc-light. NEVER touches the real operator home — every
path is a temp path the .sh constructs under SMOKE_TMP_ROOT.
"""
from __future__ import annotations

import json
import os
import sys

CRED_KEY = "claudeAi" + "Oauth"
ACCESS = "access" + "Token"
REFRESH = "refresh" + "Token"
FAR_FUTURE_MS = 4102444800000


def _fail(msg: str) -> None:
    print(f"HELPER-FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def seed_registry(path: str, token: str, auto_rotate: bool) -> None:
    reg = {
        "version": 1,
        "active_token_id": "t1",
        "auto_rotate_enabled": bool(auto_rotate),
        "rotation_threshold": 99.0,
        "weekly_warn_threshold": 95.0,
        "tokens": [{"id": "t1", "token": token, "enabled": True}],
        "last_rotation": {},
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(reg))


def set_rotate(path: str, enabled: bool) -> None:
    reg = json.load(open(path, encoding="utf-8"))
    reg["auto_rotate_enabled"] = bool(enabled)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(reg))


def seed_cred(path: str) -> None:
    """An existing operator login: old token + refreshToken + unknown fields."""
    payload = {
        CRED_KEY: {
            ACCESS: "ZZZold-stale-token-bbbbbbbbbbbb",
            REFRESH: "ZZZrefresh-keepme-cccccccccc",
            "expiresAt": 111,
            "scopes": ["user:inference"],
            "subscriptionType": "max",
        },
        "someUnknownTopLevel": {"keep": "this"},
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, indent=2))
    os.chmod(path, 0o600)


def seed_cred_noauth(path: str) -> None:
    """A valid-JSON credential file that LACKS claudeAiOauth (unrecognized)."""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"someOtherField": {"a": 1}}))
    os.chmod(path, 0o600)


def seed_config(path: str, email: str) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"oauthAccount": {"emailAddress": email}}))


def assert_patched(path: str, token: str) -> None:
    d = json.load(open(path, encoding="utf-8"))
    o = d.get(CRED_KEY, {})
    if o.get(ACCESS) != token:
        _fail("accessToken was not updated to the active token")
    if o.get(REFRESH) != "ZZZrefresh-keepme-cccccccccc":
        _fail("refreshToken was LOST (overwrite, not patch)")
    if o.get("subscriptionType") != "max":
        _fail("subscriptionType (unknown oauth field) was LOST")
    if d.get("someUnknownTopLevel") != {"keep": "this"}:
        _fail("unknown top-level field was LOST")
    if o.get("expiresAt") != FAR_FUTURE_MS:
        _fail("expiresAt was not bumped to the registry far-future constant")
    mode = os.stat(path).st_mode & 0o777
    if mode != 0o600:
        _fail(f"credential mode is {oct(mode)}, expected 0o600")
    print("OK patched+preserved+0600")


def assert_created(path: str, token: str) -> None:
    d = json.load(open(path, encoding="utf-8"))
    o = d.get(CRED_KEY, {})
    if o.get(ACCESS) != token:
        _fail("created credential missing the active accessToken")
    if REFRESH in o:
        _fail("created credential unexpectedly carries a refreshToken")
    mode = os.stat(path).st_mode & 0o777
    if mode != 0o600:
        _fail(f"created credential mode is {oct(mode)}, expected 0o600")
    print("OK created+0600")


def access_token(path: str) -> None:
    d = json.load(open(path, encoding="utf-8"))
    print(d.get(CRED_KEY, {}).get(ACCESS, ""))


def json_field(field: str) -> None:
    d = json.load(sys.stdin)
    cur = d
    for part in field.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part, "")
        else:
            cur = ""
            break
    print(cur)


def main() -> None:
    mode = sys.argv[1]
    if mode == "seed-registry":
        seed_registry(sys.argv[2], sys.argv[3], sys.argv[4] == "true")
    elif mode == "set-rotate":
        set_rotate(sys.argv[2], sys.argv[3] == "true")
    elif mode == "seed-cred":
        seed_cred(sys.argv[2])
    elif mode == "seed-cred-noauth":
        seed_cred_noauth(sys.argv[2])
    elif mode == "seed-config":
        seed_config(sys.argv[2], sys.argv[3])
    elif mode == "assert-patched":
        assert_patched(sys.argv[2], sys.argv[3])
    elif mode == "assert-created":
        assert_created(sys.argv[2], sys.argv[3])
    elif mode == "access-token":
        access_token(sys.argv[2])
    elif mode == "json-field":
        json_field(sys.argv[2])
    else:
        _fail(f"unknown helper mode: {mode}")


if __name__ == "__main__":
    main()
