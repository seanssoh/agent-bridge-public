#!/usr/bin/env python3
"""Helper for scripts/smoke/1470-engine-auth-seam.sh (footgun #11 extract).

The smoke needs to drive bridge-auth.py's Python-side seam + cred-state
helpers. Inlining those bodies as `out="$(python3 - <<'PY' ... PY)"`
trips the Bash 5.3.9 read_comsub/heredoc_write deadlock the repo bans
(footgun #11 / KNOWN_ISSUES §26) and fails `lint-heredoc-ban
--baseline-check`. This standalone helper takes everything as argv (no
stdin), so the smoke calls it as a plain command substitution with no
heredoc.

Modes (argv[1]):
  seam-mirror <auth_py>
      Assert the Python descriptor mirror agrees with the bash
      descriptor for Claude/codex/antigravity and that the Claude
      credential payload key is byte-identical. Prints `py-seam-ok`.
  cred-state <auth_py> <state_file>
      Exercise the cred-generation state store: idempotent generation
      bump, mode 0600, secret-never-in-state, fail-closed corrupt-file
      migration. Prints `cred-state-ok`.

The print tokens are the exact strings the smoke `smoke_assert_eq`s on.
"""

from __future__ import annotations

import importlib.util
import os
import stat
import sys
from pathlib import Path
from types import ModuleType


def _load_bridge_auth(auth_py: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location("bauth", auth_py)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load bridge-auth.py from {auth_py!r}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _seam_mirror(auth_py: str) -> str:
    m = _load_bridge_auth(auth_py)

    # Claude payload key byte-identical.
    payload = m.claude_oauth_credentials_payload("FAKE-TOKEN-FOR-SMOKE-0001")
    assert list(payload.keys()) == ["claudeAiOauth"], payload
    assert payload["claudeAiOauth"]["accessToken"] == "FAKE-TOKEN-FOR-SMOKE-0001"

    # Descriptor mirror agrees with bash for the key facts.
    claude = m.engine_auth_descriptor("claude")
    assert claude["auth_supported"] is True
    assert claude["auth_model"] == "rotating-pool"
    assert claude["cred_dest_tail"] == ".claude/.credentials.json"
    assert claude["cred_payload_key"] == "claudeAiOauth"
    assert claude["supports_rotation"] is True

    codex = m.engine_auth_descriptor("codex")
    assert codex["auth_supported"] is True
    assert codex["auth_model"] == "single-source-sync"
    assert codex["cred_dest_tail"] == ".codex/auth.json"
    assert codex["cred_payload_key"] is None
    assert codex["supports_rotation"] is False

    agy = m.engine_auth_descriptor("antigravity")
    assert agy["auth_supported"] is False

    # Unknown engine must raise, never silently fall through to Claude.
    try:
        m.engine_auth_descriptor("bogus-engine")
    except ValueError:
        pass
    else:
        raise AssertionError("unknown engine did not raise")

    return "py-seam-ok"


def _cred_state(auth_py: str, state_file: str) -> str:
    m = _load_bridge_auth(auth_py)
    state_path = Path(state_file)

    # B1: first stamp → generation 1.
    r1 = m.stamp_cred_generation("agA", "claude", "material-v1", state_path=state_path)
    assert r1["cred_generation"] == 1, r1
    assert r1["engine"] == "claude"

    # B2: idempotent re-sync of the SAME material → no bump.
    r2 = m.stamp_cred_generation("agA", "claude", "material-v1", state_path=state_path)
    assert r2["cred_generation"] == 1, ("idempotent re-sync must not bump", r2)

    # B3: rotated material → generation 2.
    r3 = m.stamp_cred_generation("agA", "claude", "material-v2", state_path=state_path)
    assert r3["cred_generation"] == 2, r3

    # B4: a different agent has an independent counter starting at 1.
    r4 = m.stamp_cred_generation("agB", "claude", "material-x", state_path=state_path)
    assert r4["cred_generation"] == 1, r4

    # B5: state file is mode 0600.
    mode = stat.S_IMODE(os.stat(state_path).st_mode)
    assert mode == 0o600, oct(mode)

    # B6: the secret material is NEVER written to state — only its digest.
    body = state_path.read_text(encoding="utf-8")
    for secret in ("material-v1", "material-v2", "material-x"):
        assert secret not in body, f"secret leaked into cred-state: {secret}"
    # the digest IS recorded.
    assert m.cred_source_digest("material-v2") in body

    # B7: fail-closed migration — a corrupt state file degrades to a fresh
    # default on read, it does not raise.
    state_path.write_text("{ not valid json at all", encoding="utf-8")
    migrated = m.load_cred_state(state_path)
    assert migrated == m.default_cred_state(), migrated

    # B8: a non-dict top-level also migrates cleanly.
    state_path.write_text("[1, 2, 3]", encoding="utf-8")
    migrated2 = m.load_cred_state(state_path)
    assert migrated2 == m.default_cred_state(), migrated2

    return "cred-state-ok"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: 1470-engine-auth-seam-helper.py <mode> ...", file=sys.stderr)
        return 2
    mode = argv[1]
    if mode == "seam-mirror":
        if len(argv) != 3:
            print("seam-mirror requires <auth_py>", file=sys.stderr)
            return 2
        print(_seam_mirror(argv[2]))
        return 0
    if mode == "cred-state":
        if len(argv) != 4:
            print("cred-state requires <auth_py> <state_file>", file=sys.stderr)
            return 2
        print(_cred_state(argv[2], argv[3]))
        return 0
    print(f"unknown mode: {mode!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
