#!/usr/bin/env python3
"""Helper for scripts/smoke/1470-codex-fleet-sync.sh (footgun #11 extract).

Drives bridge-auth.py's Codex fleet-sync adapter directly (importing the
module) so the smoke can assert the Python-side teeth without a full agent
runtime. Inlining these bodies as `python3 - <<'PY' … PY` would trip the
Bash 5.3.9 read_comsub/heredoc_write deadlock the repo bans (footgun #11 /
KNOWN_ISSUES §26). Everything is argv (no stdin).

Modes (argv[1]):
  wellformed <auth_py>
      codex_auth_wellformed accepts a tokens/apikey shape and rejects a
      non-object / unrecognized shape. Prints `wellformed-ok`.
  snapshot <auth_py> <good_file> <bad_file>
      read_codex_auth_snapshot validates + digests a good file and raises
      ValueError on a malformed one. Prints `snapshot-ok`.
  source-binding <auth_py> <binding_file>
      save/load round-trips the source binding fail-closed at 0600.
      Prints `source-binding-ok`.

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
    spec = importlib.util.spec_from_file_location("bauth_codex", auth_py)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load bridge-auth.py from {auth_py!r}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _wellformed(auth_py: str) -> str:
    m = _load_bridge_auth(auth_py)
    # Accept: subscription tokens object.
    ok, _ = m.codex_auth_wellformed({"tokens": {"access_token": "X"}})
    assert ok, "tokens shape rejected"
    # Accept: API-key login.
    ok, _ = m.codex_auth_wellformed({"OPENAI_API_KEY": "sk-fake"})
    assert ok, "apikey shape rejected"
    # Reject: not an object.
    ok, reason = m.codex_auth_wellformed([1, 2, 3])
    assert not ok and reason, "non-object accepted"
    # Reject: object with no recognized credential.
    ok, reason = m.codex_auth_wellformed({"hello": "world"})
    assert not ok and reason, "unrecognized shape accepted"
    # Reject: empty tokens object + blank apikey.
    ok, _ = m.codex_auth_wellformed({"tokens": {}, "OPENAI_API_KEY": "   "})
    assert not ok, "empty creds accepted"
    return "wellformed-ok"


def _snapshot(auth_py: str, good_file: str, bad_file: str) -> str:
    from pathlib import Path

    m = _load_bridge_auth(auth_py)
    raw, parsed, digest = m.read_codex_auth_snapshot(Path(good_file))
    assert isinstance(parsed, dict)
    assert len(digest) == 64, digest  # sha256 hex
    # The digest is over the RAW bytes — recompute to confirm.
    assert digest == m.cred_source_digest(raw)
    # Malformed file fails loud (ValueError), never returns a digest.
    try:
        m.read_codex_auth_snapshot(Path(bad_file))
    except ValueError:
        pass
    else:
        raise AssertionError("malformed snapshot did not raise")
    # Missing file fails loud too.
    try:
        m.read_codex_auth_snapshot(Path(good_file + ".nope"))
    except ValueError:
        pass
    else:
        raise AssertionError("missing snapshot did not raise")
    return "snapshot-ok"


def _source_binding(auth_py: str, binding_file: str) -> str:
    from pathlib import Path

    m = _load_bridge_auth(auth_py)
    p = Path(binding_file)
    # Empty by default.
    b0 = m.load_codex_source_binding(p)
    assert b0["source_agent"] == "", b0
    # Persist + reload.
    m.save_codex_source_binding("src-agent", path=p)
    b1 = m.load_codex_source_binding(p)
    assert b1["source_agent"] == "src-agent", b1
    # Fail-closed 0600.
    mode = stat.S_IMODE(os.stat(p).st_mode)
    assert mode == 0o600, oct(mode)
    # Corrupt file degrades to empty binding (does not raise).
    p.write_text("{ not json", encoding="utf-8")
    b2 = m.load_codex_source_binding(p)
    assert b2["source_agent"] == "", b2
    return "source-binding-ok"


def _dirfd_writer(auth_py: str, work_dir: str) -> str:
    """Exercise write_private_file_atomic_dirfd's TOCTOU hardening (codex r2).

    - A symlinked PARENT fails at open (O_DIRECTORY|O_NOFOLLOW).
    - A write whose resolved parent escapes allowed_root is rejected.
    - A normal write lands 0600 and byte-identical.
    """
    m = _load_bridge_auth(auth_py)
    root = Path(work_dir)
    root.mkdir(parents=True, exist_ok=True)

    # Normal write inside allowed_root → succeeds, 0600, byte-identical.
    home = root / "home"
    (home / ".codex").mkdir(parents=True, exist_ok=True)
    dest = home / ".codex" / "auth.json"
    m.write_private_file_atomic_dirfd(dest, "PAYLOAD-A", mode=0o600, allowed_root=home)
    assert dest.read_text(encoding="utf-8") == "PAYLOAD-A"
    assert stat.S_IMODE(os.stat(dest).st_mode) == 0o600

    # Symlinked parent → fail at open (PermissionError); no leak through it.
    shome = root / "shome"
    shome.mkdir(parents=True, exist_ok=True)
    evil = root / "evil"
    evil.mkdir(parents=True, exist_ok=True)
    (shome / ".codex").symlink_to(evil)
    try:
        m.write_private_file_atomic_dirfd(
            shome / ".codex" / "auth.json", "PAYLOAD-B", mode=0o600, allowed_root=shome
        )
    except PermissionError:
        pass
    else:
        raise AssertionError("symlinked parent was not rejected by the dir_fd writer")
    assert not (evil / "auth.json").exists(), "write leaked through the symlinked parent"

    # allowed_root mismatch → rejected (resolved parent not under it).
    other = root / "other"
    (other / ".codex").mkdir(parents=True, exist_ok=True)
    try:
        m.write_private_file_atomic_dirfd(
            other / ".codex" / "auth.json", "PAYLOAD-C", mode=0o600, allowed_root=home
        )
    except PermissionError:
        pass
    else:
        raise AssertionError("allowed_root mismatch was not rejected")

    return "dirfd-writer-ok"


def _live_swap(auth_py: str, work_dir: str) -> str:
    """Live parent-swap negative control (codex Phase-4 BLOCKING repro).

    Monkeypatch os.open so the FIRST O_DIRECTORY open of the dest parent
    races the attacker swap: rename the OPENED `.codex` OUTSIDE allowed_root
    and drop an in-root `.codex` decoy. The writer must REFUSE (the fd's own
    identity, not a string re-resolution, is checked) and write NOTHING inside
    OR outside. This is the exact proof codex ran on a non-procfs host where
    the old string fallback let the write land outside; the fix uses
    F_GETPATH (Darwin) / /proc/self/fd (Linux) on the OPEN fd, fail-closed
    otherwise — so the tooth must REFUSE on BOTH platforms.
    """
    m = _load_bridge_auth(auth_py)
    root = Path(work_dir)
    root.mkdir(parents=True, exist_ok=True)
    home = root / "home"
    outside = root / "outside"
    home.mkdir(parents=True, exist_ok=True)
    outside.mkdir(parents=True, exist_ok=True)
    (home / ".codex").mkdir(parents=True, exist_ok=True)

    codex_dir = str(home / ".codex")
    real_os_open = os.open
    state = {"done": False}

    def patched_open(path, flags, *a, **k):
        fd = real_os_open(path, flags, *a, **k)
        if (
            not state["done"]
            and isinstance(path, str)
            and os.path.abspath(path) == os.path.abspath(codex_dir)
            and (flags & os.O_DIRECTORY)
        ):
            state["done"] = True
            # The opened fd now points at this dir — move it OUT of root...
            os.rename(codex_dir, str(outside / ".codex"))
            # ...and drop an in-root decoy a STRING re-resolution would accept.
            os.mkdir(codex_dir)
        return fd

    # Patch os.open in the loaded module's namespace (it calls os.open).
    m.os.open = patched_open
    accepted = False
    try:
        m.write_private_file_atomic_dirfd(
            home / ".codex" / "auth.json",
            "ATTACKER-WINS-IF-WRITTEN",
            mode=0o600,
            allowed_root=home,
        )
        accepted = True
    except PermissionError:
        pass
    finally:
        m.os.open = real_os_open

    assert not accepted, "live parent-swap was ACCEPTED (TOCTOU still open)"
    assert not (home / ".codex" / "auth.json").exists(), "credential written into the in-root decoy"
    assert not (outside / ".codex" / "auth.json").exists(), "credential leaked OUTSIDE allowed_root"
    return "live-swap-refused-ok"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: 1470-codex-fleet-sync-helper.py <mode> ...", file=sys.stderr)
        return 2
    mode = argv[1]
    if mode == "wellformed":
        print(_wellformed(argv[2]))
        return 0
    if mode == "snapshot":
        print(_snapshot(argv[2], argv[3], argv[4]))
        return 0
    if mode == "source-binding":
        print(_source_binding(argv[2], argv[3]))
        return 0
    if mode == "dirfd-writer":
        print(_dirfd_writer(argv[2], argv[3]))
        return 0
    if mode == "live-swap":
        print(_live_swap(argv[2], argv[3]))
        return 0
    print(f"unknown mode: {mode!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
