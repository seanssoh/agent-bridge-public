#!/usr/bin/env python3
"""#1444 BLOCKING 2 canary — the cron keychain-free preflight subprocess must
not inherit the cron runner's ambient credential env.

``bridge-cron-runner.py``'s ``validate_claude_keychain_free_auth`` spawns
``bridge-auth.py api-key-helper --check`` as a status-only preflight. It reads
the active OAT from the locked registry, never from the environment, so the
subprocess must be given an explicit scrubbed ``env=`` rather than inheriting
``os.environ`` (which, in a real cron run, may still carry a
``CLAUDE_CODE_OAUTH_TOKEN`` the runner only pops from the eventual Claude child
env dict — not from its own process env).

This canary imports the cron runner, sets a MOCK token in ``os.environ``,
monkeypatches ``subprocess.run`` to capture the ``env=`` kwarg the preflight
passes (short-circuiting the real subprocess with a fake ``status: ok``
payload), and asserts the captured env has the three well-known credential
vars stripped. File-as-argv (footgun #11): no stdin heredoc; takes no args.

Exit 0 on pass, 1 on the leak (env not scrubbed), 2 on harness error.
MOCK tokens only — never reads or prints a real credential.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOKEN_VAR = "CLAUDE_CODE_OAUTH_TOKEN"
SIBLING_VARS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")
MOCK_TOKEN = "MOCK-CANARY-NOT-A-REAL-TOKEN"


def _load_cron_runner():
    path = REPO_ROOT / "bridge-cron-runner.py"
    spec = importlib.util.spec_from_file_location("bridge_cron_runner_canary", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    try:
        cron = _load_cron_runner()
    except Exception as exc:  # pragma: no cover - harness error
        print(f"[canary] could not import cron runner: {exc}", file=sys.stderr)
        return 2

    # Force the keychain-free + Darwin gate ON so validate_* reaches the
    # subprocess, regardless of host platform or runtime config.
    os.environ["BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH"] = "1"
    os.environ["BRIDGE_HOST_PLATFORM_OVERRIDE"] = "Darwin"
    # Plant the ambient credentials the preflight must NOT inherit.
    os.environ[TOKEN_VAR] = MOCK_TOKEN
    for var in SIBLING_VARS:
        os.environ[var] = MOCK_TOKEN

    captured: dict[str, object] = {}

    class _FakeCompleted:
        returncode = 0
        stdout = '{"status": "ok"}'
        stderr = ""

    real_run = cron.subprocess.run

    def _fake_run(cmd, *args, **kwargs):  # noqa: ANN001 - test shim
        # Only intercept the preflight's api-key-helper --check call; defer
        # anything else (there shouldn't be any) to the real implementation.
        if isinstance(cmd, (list, tuple)) and "api-key-helper" in cmd:
            captured["env"] = kwargs.get("env")
            return _FakeCompleted()
        return real_run(cmd, *args, **kwargs)

    cron.subprocess.run = _fake_run

    # The function also stats the helper + settings file on the Darwin gate
    # before the subprocess. Monkeypatch those filesystem preconditions so the
    # canary stays a pure env-scrub assertion (we are not testing file checks).
    cron.claude_api_key_helper_path = lambda: REPO_ROOT / "scripts" / "claude-oat-api-key-helper.sh"  # type: ignore[assignment]

    # Build a config_dir with a valid settings.json pointing at the helper so
    # the pre-subprocess validation passes and we reach the spawn.
    import json
    import tempfile

    tmp = Path(tempfile.mkdtemp(prefix="agb-cron-preflight-canary."))
    helper = cron.claude_api_key_helper_path()
    (tmp / "settings.json").write_text(
        json.dumps({"apiKeyHelper": str(helper)}), encoding="utf-8"
    )

    # os.access(helper, X_OK) must pass; the in-repo helper is executable.
    try:
        cron.validate_claude_keychain_free_auth(tmp)
    except Exception as exc:
        print(f"[canary] validate raised before/around spawn: {exc}", file=sys.stderr)
        return 2

    if "env" not in captured:
        print("[canary] preflight subprocess was never intercepted", file=sys.stderr)
        return 2
    env = captured["env"]
    if env is None:
        print(
            "[canary] BLOCKING 2 NOT fixed: preflight passed env=None "
            "(inherits ambient os.environ incl. the token)",
            file=sys.stderr,
        )
        return 1
    if not isinstance(env, dict):
        print(f"[canary] unexpected env kwarg type: {type(env)!r}", file=sys.stderr)
        return 2
    leaked = [v for v in (TOKEN_VAR, *SIBLING_VARS) if v in env]
    if leaked:
        print(
            f"[canary] BLOCKING 2 NOT fixed: preflight env still carries {leaked}",
            file=sys.stderr,
        )
        return 1
    print("[canary] OK: cron preflight subprocess env is scrubbed of credential vars")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
