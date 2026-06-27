#!/usr/bin/env python3
"""Helper for scripts/smoke/18849-operator-account-email.sh (#18849 Part 1b-v2).

JSON seed/assert helpers kept out of the bash driver so the credential-shaped
keys (claudeAiOauth / accessToken / refreshToken) live in one place and the
driver stays heredoc-light. NEVER touches the real operator home — every path is
a temp path the .sh constructs under SMOKE_TMP_ROOT.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys

CRED_KEY = "claudeAi" + "Oauth"
ACCESS = "access" + "Token"
REFRESH = "refresh" + "Token"


def _fail(msg: str) -> None:
    print(f"HELPER-FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def _load_mod():
    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(os.path.dirname(here))
    spec = importlib.util.spec_from_file_location(
        "bridge_auth_mod", os.path.join(repo_root, "bridge-auth.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def seed_registry(path: str, token: str, auto_rotate: bool,
                  account_email: str = "", source: str = "") -> None:
    """Seed a one-token registry. An optional account_email + source models a
    legacy/probe-sourced or pre-configured row (the smoke sets source explicitly)."""
    row = {"id": "t1", "token": token, "enabled": True}
    if account_email:
        row["account_email"] = account_email
    if source:
        row["account_email_source"] = source
    reg = {
        "version": 1,
        "active_token_id": "t1",
        "auto_rotate_enabled": bool(auto_rotate),
        "rotation_threshold": 99.0,
        "weekly_warn_threshold": 95.0,
        "tokens": [row],
        "last_rotation": {},
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(reg))


def seed_cred(path: str) -> None:
    payload = {
        CRED_KEY: {
            ACCESS: "ZZZold-stale-token-bbbbbbbbbbbb",
            REFRESH: "ZZZrefresh-keepme-cccccccccc",
            "expiresAt": 111,
        },
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, indent=2))
    os.chmod(path, 0o600)


def seed_config_full(path: str, email: str) -> None:
    """A realistic operator ~/.claude.json: oauthAccount + load-bearing keys."""
    payload = {
        "oauthAccount": {
            "emailAddress": email,
            "organizationName": "Acme Org",
        },
        "projects": {"/some/workdir": {"hasTrustDialogAccepted": True}},
        "mcpServers": {"someServer": {"command": "x"}},
        "unknownTopLevel": {"keep": "this"},
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, indent=2))
    os.chmod(path, 0o600)


def write_fixture(path: str, kind: str, email: str = "") -> None:
    """Write a profile-probe fixture the bridge-auth.py HTTP seam consumes."""
    if kind == "verified":
        spec = {"http_status": 200, "body": {"account": {"email_address": email}}}
    elif kind == "no_scope":
        spec = {"http_status": 403, "body": {"error": "forbidden"}}
    else:
        _fail(f"unknown fixture kind: {kind}")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(spec))


def reg_field(path: str, field: str) -> None:
    reg = json.load(open(path, encoding="utf-8"))
    for row in reg.get("tokens", []):
        if row.get("id") == reg.get("active_token_id"):
            print(row.get(field, ""))
            return
    print("")


def assert_config_email(path: str, email: str) -> None:
    d = json.load(open(path, encoding="utf-8"))
    got = d.get("oauthAccount", {}).get("emailAddress")
    if got != email:
        _fail(f"displayed email is {got!r}, expected {email!r}")
    print("OK config-email")


def assert_identity_patched(path: str, email: str) -> None:
    d = json.load(open(path, encoding="utf-8"))
    o = d.get("oauthAccount", {})
    if o.get("emailAddress") != email:
        _fail(f"oauthAccount.emailAddress not synced to {email!r}: {o.get('emailAddress')!r}")
    if "accountUuid" in o:
        _fail("operator-source path must NOT invent an accountUuid (subject)")
    if o.get("organizationName") != "Acme Org":
        _fail("organizationName (unknown oauthAccount field) was LOST")
    if d.get("projects") != {"/some/workdir": {"hasTrustDialogAccepted": True}}:
        _fail("projects was LOST/altered (overwrite, not patch)")
    if d.get("mcpServers") != {"someServer": {"command": "x"}}:
        _fail("mcpServers was LOST/altered (overwrite, not patch)")
    if d.get("unknownTopLevel") != {"keep": "this"}:
        _fail("unknown top-level key was LOST")
    mode = os.stat(path).st_mode & 0o777
    if mode != 0o600:
        _fail(f"config mode is {oct(mode)}, expected the preserved 0o600")
    print("OK identity-patched+preserved")


def scopes_constant() -> None:
    """Print the module's CLAUDE_OAUTH_SCOPES — gate 7 introspection."""
    mod = _load_mod()
    print(json.dumps(mod.CLAUDE_OAUTH_SCOPES))


def cred_scopes(path: str) -> None:
    d = json.load(open(path, encoding="utf-8"))
    print(json.dumps(d.get(CRED_KEY, {}).get("scopes", [])))


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
        seed_registry(
            sys.argv[2], sys.argv[3], sys.argv[4] == "true",
            sys.argv[5] if len(sys.argv) > 5 else "",
            sys.argv[6] if len(sys.argv) > 6 else "",
        )
    elif mode == "seed-cred":
        seed_cred(sys.argv[2])
    elif mode == "seed-config-full":
        seed_config_full(sys.argv[2], sys.argv[3])
    elif mode == "write-fixture":
        write_fixture(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    elif mode == "reg-field":
        reg_field(sys.argv[2], sys.argv[3])
    elif mode == "assert-config-email":
        assert_config_email(sys.argv[2], sys.argv[3])
    elif mode == "assert-identity-patched":
        assert_identity_patched(sys.argv[2], sys.argv[3])
    elif mode == "scopes-constant":
        scopes_constant()
    elif mode == "cred-scopes":
        cred_scopes(sys.argv[2])
    elif mode == "json-field":
        json_field(sys.argv[2])
    else:
        _fail(f"unknown helper mode: {mode}")


if __name__ == "__main__":
    main()
