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


# ── #18849 Part 1b — identity-sync helpers ──────────────────────────────
ACCT_UUID = "acct-uuid-verified-0001"


def seed_config_full(path: str, email: str) -> None:
    """A realistic operator ~/.claude.json: oauthAccount + load-bearing keys."""
    payload = {
        "oauthAccount": {
            "emailAddress": email,
            "organizationName": "Acme Org",
            "organizationRole": "admin",
        },
        "projects": {"/some/workdir": {"hasTrustDialogAccepted": True}},
        "mcpServers": {"someServer": {"command": "x"}},
        "hasCompletedOnboarding": True,
        "unknownTopLevel": {"keep": "this"},
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, indent=2))
    os.chmod(path, 0o600)


def write_fixture(path: str, kind: str, email: str = "") -> None:
    """Write a profile-probe fixture the bridge-auth.py HTTP seam consumes."""
    if kind == "verified":
        spec = {"http_status": 200, "body": {
            "account": {"email_address": email, "uuid": ACCT_UUID}}}
    elif kind == "no_email":
        spec = {"http_status": 200, "body": {"account": {"uuid": ACCT_UUID}}}
    elif kind == "no_scope":
        spec = {"http_status": 403, "body": {"error": "forbidden"}}
    elif kind == "transport_error":
        spec = {"transport_error": True}
    else:
        _fail(f"unknown fixture kind: {kind}")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(spec))


def assert_identity_patched(path: str, email: str) -> None:
    d = json.load(open(path, encoding="utf-8"))
    o = d.get("oauthAccount", {})
    if o.get("emailAddress") != email:
        _fail(f"oauthAccount.emailAddress not synced to {email!r}: {o.get('emailAddress')!r}")
    if o.get("accountUuid") != ACCT_UUID:
        _fail("verified accountUuid (subject) was not written")
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


def assert_config_email(path: str, email: str) -> None:
    d = json.load(open(path, encoding="utf-8"))
    got = d.get("oauthAccount", {}).get("emailAddress")
    if got != email:
        _fail(f"displayed email is {got!r}, expected unchanged {email!r}")
    print("OK config-email-unchanged")


def reg_identity(path: str, field: str) -> None:
    reg = json.load(open(path, encoding="utf-8"))
    for row in reg.get("tokens", []):
        if row.get("id") == reg.get("active_token_id"):
            print(row.get(field, ""))
            return
    print("")


def race_parent_swap_config(reg_path: str, op_home: str, email: str) -> None:
    """#18849 Part 1b T14-style — parent-swap AFTER lock for the .claude.json
    identity writer. Same discriminator as the credential writer's race: the
    instant the lock flocks, the locked dir is renamed away and a decoy renamed
    in (both under allowed_root). A correct single-dir_fd writer lands the new
    identity in the LOCKED dir; the r2 string-path writer would write the decoy.
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
    cfg_name = "config.json"
    os.makedirs(claude_dir, exist_ok=True)
    os.makedirs(decoy_dir, exist_ok=True)
    for d, mail in ((claude_dir, "locked-old@example.com"),
                    (decoy_dir, "decoy-untouched@example.com")):
        with open(os.path.join(d, cfg_name), "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"oauthAccount": {"emailAddress": mail}}))
        os.chmod(os.path.join(d, cfg_name), 0o600)

    real_flock = fcntl.flock
    state = {"swapped": False}

    def swapping_flock(fd, op):  # noqa: ANN001
        if not state["swapped"]:
            state["swapped"] = True
            os.rename(claude_dir, old_dir)
            os.rename(decoy_dir, claude_dir)
        return real_flock(fd, op)

    fcntl.flock = swapping_flock
    try:
        mod.patch_global_claude_identity(
            Path(os.path.join(claude_dir, cfg_name)),
            email=email,
            allowed_root=Path(op_home),
        )
    finally:
        fcntl.flock = real_flock

    if not state["swapped"]:
        _fail("flock monkeypatch never fired — the race was not exercised")

    def _email(p: str) -> str:
        try:
            return json.load(open(p, encoding="utf-8")).get(
                "oauthAccount", {}).get("emailAddress", "")
        except FileNotFoundError:
            return "<absent>"

    decoy_after = _email(os.path.join(claude_dir, cfg_name))  # swapped-in
    locked_after = _email(os.path.join(old_dir, cfg_name))    # the locked dir
    if decoy_after == email:
        _fail("RACE REPRODUCED: identity landed in the SWAPPED-IN (unlocked) dir")
    if locked_after != email:
        _fail(f"identity did not land in the LOCKED dir (.claude-old got {locked_after!r})")
    if not os.path.exists(os.path.join(old_dir, cfg_name + ".lock")):
        _fail("lock file is not in the locked directory (.claude-old)")
    print("OK race-parent-swap-config: lock-dir == write-dir; decoy untouched")


def race_token_replace_during_probe(
    reg_path: str, op_home: str, displayed_email: str, victim_email: str
) -> None:
    """#18849 Part 1b r2 — token-replace race during the in-flight profile probe.

    The verified profile probe runs on ``active_token`` — a value snapshotted
    BEFORE the registry lock is released (``_global_auth_gate_state``). A
    concurrent ``cmd_add --replace`` / rotation can swap the active row's token
    value (same id) WHILE the probe is in flight. We reproduce that by
    monkeypatching ``probe_claude_account_identity`` so that, at probe time, it
    (a) swaps t1's token value on disk and (b) returns a VERIFIED identity for a
    DIFFERENT account. A correct persist path rechecks the row's CURRENT token
    fingerprint under the registry lock and SKIPS both the registry identity
    record AND the ~/.claude.json write. Discriminator: with the fingerprint
    recheck removed, the stale verified email is stamped onto the replacement
    token AND written into ~/.claude.json.
    """
    import importlib.util
    from pathlib import Path

    # Force the keychain-exists guard OFF so the (macOS) test host's real
    # keychain state cannot pre-empt the identity path before the probe runs.
    os.environ["BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT"] = "0"

    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(os.path.dirname(here))
    spec = importlib.util.spec_from_file_location(
        "bridge_auth_mod", os.path.join(repo_root, "bridge-auth.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    os.makedirs(op_home, exist_ok=True)
    cfg_path = os.path.join(op_home, ".claude.json")
    original_token = "ZZZorig-active-token-aaaaaaaaaaaa"
    replacement_token = "ZZZswapped-in-token-bbbbbbbbbbbb"

    seed_registry(reg_path, original_token, True)
    with open(cfg_path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"oauthAccount": {"emailAddress": displayed_email}}))
    os.chmod(cfg_path, 0o600)

    real_probe = mod.probe_claude_account_identity
    state = {"fired": False}

    def replacing_probe(token, *, timeout_seconds):  # noqa: ANN001
        state["fired"] = True
        reg = json.load(open(reg_path, encoding="utf-8"))
        for row in reg.get("tokens", []):
            if row.get("id") == "t1":
                row["token"] = replacement_token  # concurrent cmd_add --replace
        with open(reg_path, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(reg))
        return {"status": "verified", "email": victim_email,
                "subject": ACCT_UUID, "detail": "fixture verified (stale token)"}

    mod.probe_claude_account_identity = replacing_probe
    try:
        result = mod.run_global_identity_sync(
            Path(reg_path), "t1", original_token, Path(cfg_path),
            credential_changed=True, allowed_root=Path(op_home),
        )
    finally:
        mod.probe_claude_account_identity = real_probe

    if not state["fired"]:
        _fail("probe monkeypatch never fired — the race was not exercised")
    if result.get("status") != "skipped" or result.get("reason") != "token_replaced":
        _fail(f"expected status=skipped reason=token_replaced, got {result!r}")

    reg = json.load(open(reg_path, encoding="utf-8"))
    row = next((r for r in reg.get("tokens", []) if r.get("id") == "t1"), {})
    if row.get("token") != replacement_token:
        _fail("precondition: registry token was not actually replaced mid-probe")
    if row.get("account_email") == victim_email:
        _fail("RACE REPRODUCED: stale verified email recorded onto the REPLACED token row")
    if row.get("account_email_probe_status") == "verified":
        _fail("RACE REPRODUCED: probe_status=verified persisted onto the replaced token row")

    cfg = json.load(open(cfg_path, encoding="utf-8"))
    got = cfg.get("oauthAccount", {}).get("emailAddress")
    if got != displayed_email:
        _fail(f"RACE REPRODUCED: ~/.claude.json identity was WRITTEN to {got!r} on a token-replace race")
    print("OK race-token-replace-during-probe: no identity record, no ~/.claude.json write")


def race_post_persist_write_under_lock(
    reg_path: str, op_home: str, displayed_email: str, new_email: str
) -> None:
    """#18849 Part 1b r2 — the verified-identity WRITE must run while the
    registry lock is HELD, closing the post-persist/pre-patch token-replace
    window (codex r2 Finding 1). A concurrent ``cmd_add --replace`` swaps the
    active token under ``registry_lock``; if the ~/.claude.json write ran AFTER
    the registry lock was released, a replace landing in that gap would let a
    stale verified email reach the config writer. We wrap
    ``patch_global_claude_identity`` so that, at write time, it proves a
    non-blocking ``registry_lock`` acquisition would BLOCK (i.e. the lock is
    still held by ``run_global_identity_sync``). Discriminator: if the write
    were moved OUTSIDE the registry lock, the non-blocking flock would SUCCEED
    and this fails.
    """
    import fcntl
    import importlib.util
    from pathlib import Path

    os.environ["BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT"] = "0"

    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(os.path.dirname(here))
    spec = importlib.util.spec_from_file_location(
        "bridge_auth_mod", os.path.join(repo_root, "bridge-auth.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    os.makedirs(op_home, exist_ok=True)
    cfg_path = os.path.join(op_home, ".claude.json")
    token = "ZZZorig-active-token-aaaaaaaaaaaa"
    seed_registry(reg_path, token, True)
    with open(cfg_path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"oauthAccount": {"emailAddress": displayed_email}}))
    os.chmod(cfg_path, 0o600)

    # Resolve the registry lock file path exactly the way bridge-auth.py does.
    reg = Path(reg_path)
    lock_path = str(reg.with_suffix(reg.suffix + mod.REGISTRY_LOCK_SUFFIX))

    real_probe = mod.probe_claude_account_identity
    real_writer = mod.patch_global_claude_identity
    state = {"write_called": False, "lock_held_during_write": None}

    def verified_probe(token, *, timeout_seconds):  # noqa: ANN001
        return {"status": "verified", "email": new_email,
                "subject": ACCT_UUID, "detail": "fixture verified"}

    def probing_writer(config_path, *, email, subject="", owner_uid=None,
                       allowed_root=None):  # noqa: ANN001
        state["write_called"] = True
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
            state["lock_held_during_write"] = False  # got it -> NOT held -> BUG
        except BlockingIOError:
            state["lock_held_during_write"] = True   # blocked -> held -> correct
        finally:
            os.close(fd)
        return real_writer(config_path, email=email, subject=subject,
                           owner_uid=owner_uid, allowed_root=allowed_root)

    mod.probe_claude_account_identity = verified_probe
    mod.patch_global_claude_identity = probing_writer
    try:
        result = mod.run_global_identity_sync(
            Path(reg_path), "t1", token, Path(cfg_path),
            credential_changed=True, allowed_root=Path(op_home),
        )
    finally:
        mod.probe_claude_account_identity = real_probe
        mod.patch_global_claude_identity = real_writer

    if not state["write_called"]:
        _fail("patch_global_claude_identity was never called — write seam not exercised")
    if state["lock_held_during_write"] is not True:
        _fail("POST-PERSIST WINDOW OPEN: registry lock was NOT held during the "
              "~/.claude.json identity write (a token replace could race in)")
    if result.get("status") not in ("synced", "converged"):
        _fail(f"expected a successful identity write, got {result!r}")
    got = json.load(open(cfg_path, encoding="utf-8")).get(
        "oauthAccount", {}).get("emailAddress")
    if got != new_email:
        _fail(f"identity write did not land: got {got!r}, expected {new_email!r}")
    print("OK race-post-persist: ~/.claude.json identity write runs under the registry lock")


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
    elif mode == "seed-config-full":
        seed_config_full(sys.argv[2], sys.argv[3])
    elif mode == "write-fixture":
        write_fixture(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    elif mode == "assert-identity-patched":
        assert_identity_patched(sys.argv[2], sys.argv[3])
    elif mode == "assert-config-email":
        assert_config_email(sys.argv[2], sys.argv[3])
    elif mode == "reg-identity":
        reg_identity(sys.argv[2], sys.argv[3])
    elif mode == "race-parent-swap-config":
        race_parent_swap_config(sys.argv[2], sys.argv[3], sys.argv[4])
    elif mode == "race-token-replace-during-probe":
        race_token_replace_during_probe(
            sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif mode == "race-post-persist-write-under-lock":
        race_post_persist_write_under_lock(
            sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
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
