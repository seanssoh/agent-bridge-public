#!/usr/bin/env python3
"""File-as-argv sidecar for scripts/smoke/1835-create-bodyfile-iso-fallback.sh.

Footgun #11 / C1: the smoke must NOT pipe `python3 - <<'PY'` heredoc-stdin to a
subprocess (deadlock class banned by lint-heredoc-ban). Every Python snippet the
1835 smoke needs lives here and is invoked `python3 <helper> <case> <args...>`.

The cases exercise bridge-queue-gateway.py:_read_inline_text — the SOCKET
transport's client-side body-file preflight — to prove the Issue #1835 fix:
the #1280 sudo-as-owner fallback is now applied on PermissionError, with an
actionable iso-ownership error when the fallback cannot apply.
"""
from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path


def _load_gateway(repo_root: str):
    path = Path(repo_root) / "bridge-queue-gateway.py"
    spec = importlib.util.spec_from_file_location("bridge_queue_gateway_1835", str(path))
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def case_direct_read_no_fallback(repo_root: str, body_path: str) -> int:
    """A readable file is read directly; the sudo fallback must NOT fire."""
    gw = _load_gateway(repo_root)
    fired = {"n": 0}
    orig = gw._sudo_read_body_file

    def spy(path):
        fired["n"] += 1
        return orig(path)

    gw._sudo_read_body_file = spy
    out = gw._read_inline_text(body_path)
    if fired["n"] != 0:
        print(f"FAIL: fallback fired on a readable file (n={fired['n']})")
        return 1
    with open(body_path, "r", encoding="utf-8") as f:
        expected = f.read()
    if out != expected:
        print(f"FAIL: direct read mismatch: {out!r} != {expected!r}")
        return 1
    print("ok-direct-read-no-fallback")
    return 0


def case_fallback_success(repo_root: str, body_path: str) -> int:
    """PermissionError on open -> sudo fallback succeeds -> decoded bytes."""
    gw = _load_gateway(repo_root)

    def deny_open(path, flags, *a, **k):
        raise PermissionError(13, "Permission denied")

    gw_os_open = os.open
    os.open = deny_open
    gw._sudo_read_body_file = lambda path: b"recovered via sudo owner cat\n"
    try:
        out = gw._read_inline_text(body_path)
    finally:
        os.open = gw_os_open
    if out != "recovered via sudo owner cat\n":
        print(f"FAIL: fallback-success mismatch: {out!r}")
        return 1
    print("ok-fallback-success")
    return 0


def case_fallback_unavailable_actionable(repo_root: str, body_path: str) -> int:
    """PermissionError + fallback None -> actionable iso-ownership error."""
    gw = _load_gateway(repo_root)

    def deny_open(path, flags, *a, **k):
        raise PermissionError(13, "Permission denied")

    gw_os_open = os.open
    os.open = deny_open
    gw._sudo_read_body_file = lambda path: None
    reason_code = None
    msg = ""
    try:
        gw._read_inline_text(body_path)
        print("FAIL: expected ClientPreflightError, got a return")
        return 1
    except gw.ClientPreflightError as exc:
        reason_code = exc.reason_code
        msg = gw._format_client_preflight_error(exc)
    finally:
        os.open = gw_os_open
    if reason_code != "body_file_unreadable":
        print(f"FAIL: reason_code={reason_code!r}")
        return 1
    for needle in ("iso UID may own this file", "--body", "chmod 0644", "#1280"):
        if needle not in msg:
            print(f"FAIL: actionable error missing {needle!r}: {msg}")
            return 1
    print("ok-fallback-unavailable-actionable")
    return 0


def case_fallback_size_cap(repo_root: str, body_path: str) -> int:
    """Bytes recovered via the fallback still respect the inline size cap."""
    gw = _load_gateway(repo_root)

    def deny_open(path, flags, *a, **k):
        raise PermissionError(13, "Permission denied")

    gw_os_open = os.open
    os.open = deny_open
    gw._sudo_read_body_file = lambda path: b"x" * (gw.INLINE_BODY_CAP_BYTES + 5)
    reason_code = None
    try:
        gw._read_inline_text(body_path)
        print("FAIL: expected body_file_too_large")
        return 1
    except gw.ClientPreflightError as exc:
        reason_code = exc.reason_code
    finally:
        os.open = gw_os_open
    if reason_code != "body_file_too_large":
        print(f"FAIL: reason_code={reason_code!r}")
        return 1
    print("ok-fallback-size-cap")
    return 0


_CASES = {
    "direct-read-no-fallback": case_direct_read_no_fallback,
    "fallback-success": case_fallback_success,
    "fallback-unavailable-actionable": case_fallback_unavailable_actionable,
    "fallback-size-cap": case_fallback_size_cap,
}


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(f"usage: {argv[0]} <case> <repo_root> <body_path>", file=sys.stderr)
        return 2
    case = argv[1]
    fn = _CASES.get(case)
    if fn is None:
        print(f"unknown case: {case}", file=sys.stderr)
        return 2
    return fn(argv[2], argv[3])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
