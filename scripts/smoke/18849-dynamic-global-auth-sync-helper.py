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


def _seed_oauth(path: str, token: str) -> None:
    payload = {
        CRED_KEY: {ACCESS: token, REFRESH: "ZZZkeep-" + token[-8:], "expiresAt": 1},
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, indent=2))
    os.chmod(path, 0o600)


def _read_access(path: str) -> str:
    try:
        d = json.load(open(path, encoding="utf-8"))
    except FileNotFoundError:
        return "<absent>"
    return d.get(CRED_KEY, {}).get(ACCESS, "<no-access>")


def race_parent_swap(reg_path: str, op_home: str, rotated_token: str) -> None:
    """#18887 r3 regression — parent-swap AFTER lock acquisition.

    Monkeypatch ``fcntl.flock`` so the instant the global-credentials lock
    flocks its fd (i.e. AFTER the parent was opened+validated and the lock fd
    created in it), we rename the locked ``.claude`` away and rename a decoy
    dir into ``.claude`` — BOTH under allowed_root, so containment alone cannot
    catch it; only "lock-dir == write-dir" does. A correct single-dir_fd
    implementation writes the rotated token into the LOCKED directory (now
    ``.claude-old``) and leaves the swapped-in decoy untouched. The r2
    string-path writer re-resolved ``str(path.parent)`` and would instead write
    the rotated token into the unlocked decoy — the residual TOCTOU.
    """
    import fcntl
    import importlib.util
    from pathlib import Path

    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(os.path.dirname(here))
    spec = importlib.util.spec_from_file_location(
        "bridge_auth_mod", os.path.join(repo_root, "bridge-auth.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    claude_dir = os.path.join(op_home, ".claude")
    decoy_dir = os.path.join(op_home, ".claude-decoy")
    old_dir = os.path.join(op_home, ".claude-old")
    cred_name = ".credentials.json"
    locked_token = "ZZZlocked-old-token-dddddddddddd"
    decoy_token = "ZZZdecoy-untouched-token-eeeeeeee"

    os.makedirs(claude_dir, exist_ok=True)
    os.makedirs(decoy_dir, exist_ok=True)
    _seed_oauth(os.path.join(claude_dir, cred_name), locked_token)
    _seed_oauth(os.path.join(decoy_dir, cred_name), decoy_token)

    real_flock = fcntl.flock
    state = {"swapped": False}

    def swapping_flock(fd, op):  # noqa: ANN001
        if not state["swapped"]:
            state["swapped"] = True
            os.rename(claude_dir, old_dir)   # locked dir moves out from under .claude
            os.rename(decoy_dir, claude_dir)  # decoy takes .claude's place (in-root)
        return real_flock(fd, op)

    fcntl.flock = swapping_flock
    try:
        mod.patch_global_claude_credentials(
            Path(os.path.join(claude_dir, cred_name)),
            rotated_token,
            allowed_root=Path(op_home),
        )
    finally:
        fcntl.flock = real_flock

    if not state["swapped"]:
        _fail("flock monkeypatch never fired — the race was not exercised")
    locked_after = _read_access(os.path.join(old_dir, cred_name))  # the locked dir
    decoy_after = _read_access(os.path.join(claude_dir, cred_name))  # swapped-in
    if decoy_after == rotated_token:
        _fail(
            "RACE REPRODUCED: rotated token landed in the SWAPPED-IN (unlocked) "
            "directory — parent-swap-after-lock TOCTOU is open"
        )
    if locked_after != rotated_token:
        _fail(
            f"write did not land in the LOCKED directory (.claude-old got "
            f"{locked_after!r}, expected the rotated token)"
        )
    # The lock and the write must be the same directory: the lock file lives in
    # the locked dir (now .claude-old), NOT in the swapped-in decoy (.claude).
    if not os.path.exists(os.path.join(old_dir, cred_name + ".lock")):
        _fail("lock file is not in the locked directory (.claude-old)")
    print("OK race-parent-swap: lock-dir == write-dir; decoy untouched")


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
    elif mode == "race-parent-swap":
        race_parent_swap(sys.argv[2], sys.argv[3], sys.argv[4])
    elif mode == "json-field":
        json_field(sys.argv[2])
    else:
        _fail(f"unknown helper mode: {mode}")


if __name__ == "__main__":
    main()
