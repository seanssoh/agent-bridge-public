#!/usr/bin/env python3
"""Helper for scripts/smoke/2164-rotate-global-sync.sh (#2164).

Seeds the 2-token rotation registry + a FAKE operator-global credential file and
computes token FINGERPRINTS (never raw token bytes) by importing the real
bridge-auth.py ``token_fingerprint``, so the bash driver can assert the inline
converge (``_converge_operator_global_inline``) on ``rotate``/``activate
--sync`` WITHOUT ever handling a raw token. The synthetic tokens live only in
this helper. NEVER touches the real operator home — every path is a temp path
the .sh constructs under SMOKE_TMP_ROOT.

Footgun #11 (heredoc_write deadlock class): the driver shells out to this helper
with file-as-argv instead of heredoc-stdin into bridge-auth.py / bridge-auth.sh.
"""
from __future__ import annotations

import json
import os
import sys

CRED_KEY = "claudeAi" + "Oauth"
ACCESS = "access" + "Token"
REFRESH = "refresh" + "Token"

# Benign, non-credential-shaped synthetic tokens (validate_token only requires
# len>=20 and no whitespace/quotes) — nothing here resembles a real Anthropic
# credential. ``ta`` is the seeded active token; a rotation/activation moves the
# active pointer to ``tb``.
TOKENS = {
    "ta": "ZZZ2164-old-active-token-aaaaaaaaaaaa",
    "tb": "ZZZ2164-new-active-token-bbbbbbbbbbbb",
}
REFRESH_KEEP = "ZZZ2164-refresh-keepme-cccccccccc"


def _fail(msg: str) -> None:
    print(f"HELPER-FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def _load_auth():
    """Import the repo-root bridge-auth.py by path for token_fingerprint."""
    import importlib.util

    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(os.path.dirname(here))
    spec = importlib.util.spec_from_file_location(
        "bridge_auth_2164", os.path.join(repo_root, "bridge-auth.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def seed_registry(path: str, active_id: str, auto_rotate: str) -> None:
    """A healthy 2-token pool (both enabled) so cmd_rotate has an alternate."""
    reg = {
        "version": 1,
        "active_token_id": active_id,
        "auto_rotate_enabled": auto_rotate == "true",
        "rotation_threshold": 99.0,
        "weekly_warn_threshold": 95.0,
        "tokens": [
            {"id": "ta", "token": TOKENS["ta"], "enabled": True},
            {"id": "tb", "token": TOKENS["tb"], "enabled": True},
        ],
        "last_rotation": {},
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(reg))


def seed_cred(path: str, token_id: str) -> None:
    """Seed the operator-global .credentials.json with token <token_id>'s value
    plus a refreshToken + unknown fields, so the converge's PATCH-not-overwrite
    is observable. The dynamic-vanilla agent reads THIS file (HOME=operator
    global, no CLAUDE_CONFIG_DIR)."""
    payload = {
        CRED_KEY: {
            ACCESS: TOKENS[token_id],
            REFRESH: REFRESH_KEEP,
            "expiresAt": 111,
            "scopes": ["user:inference"],
            "subscriptionType": "max",
        },
        "someUnknownTopLevel": {"keep": "this"},
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, indent=2))
    os.chmod(path, 0o600)


def cred_fp(path: str) -> None:
    """Print token_fingerprint of the operator-global accessToken (or ABSENT)."""
    mod = _load_auth()
    try:
        d = json.load(open(path, encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        print("ABSENT")
        return
    tok = d.get(CRED_KEY, {}).get(ACCESS, "")
    print(mod.token_fingerprint(tok) if tok else "ABSENT")


def active_fp(reg_path: str) -> None:
    """Print token_fingerprint of the registry's CURRENT active token."""
    mod = _load_auth()
    reg = json.load(open(reg_path, encoding="utf-8"))
    active_id = reg.get("active_token_id", "")
    for row in reg.get("tokens", []):
        if row.get("id") == active_id:
            print(mod.token_fingerprint(str(row.get("token") or "")))
            return
    print("")


def assert_cred_preserved(path: str) -> None:
    """The converge PATCHes accessToken only — refreshToken / unknown / 0600 hold."""
    d = json.load(open(path, encoding="utf-8"))
    o = d.get(CRED_KEY, {})
    if o.get(REFRESH) != REFRESH_KEEP:
        _fail("refreshToken was LOST (overwrite, not patch)")
    if o.get("subscriptionType") != "max":
        _fail("subscriptionType (unknown oauth field) was LOST")
    if d.get("someUnknownTopLevel") != {"keep": "this"}:
        _fail("unknown top-level field was LOST")
    mode = os.stat(path).st_mode & 0o777
    if mode != 0o600:
        _fail(f"credential mode is {oct(mode)}, expected the preserved 0o600")
    print("OK cred-preserved+0600")


def json_field(field: str) -> None:
    """Read dotted <field> from a JSON object on stdin (empty when absent)."""
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
        seed_registry(sys.argv[2], sys.argv[3], sys.argv[4])
    elif mode == "seed-cred":
        seed_cred(sys.argv[2], sys.argv[3])
    elif mode == "cred-fp":
        cred_fp(sys.argv[2])
    elif mode == "active-fp":
        active_fp(sys.argv[2])
    elif mode == "assert-cred-preserved":
        assert_cred_preserved(sys.argv[2])
    elif mode == "json-field":
        json_field(sys.argv[2])
    else:
        _fail(f"unknown helper mode: {mode}")


if __name__ == "__main__":
    main()
