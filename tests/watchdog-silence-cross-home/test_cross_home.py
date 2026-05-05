#!/usr/bin/env python3
"""Regression test for issue #591 — bridge-watchdog-silence.py must refuse
to run when `BRIDGE_DAEMON_PID_FILE` resolves outside `BRIDGE_HOME`.

The bug: a watchdog inheriting `BRIDGE_DAEMON_PID_FILE` from a parent shell
while pointing `BRIDGE_HOME` at a temp dir reads its own (empty) audit log,
concludes the live daemon is silent, and SIGTERMs the live PID at ~0.4
events/min until launchd KeepAlive gives up.

This test exercises `_validate_cross_home()` in four shapes:
  1. cross-home  -> SystemExit(2) and an error log
  2. same-home   -> no exit
  3. defaults    -> no exit (default pid file lives under default home)
  4. symlinked   -> no exit when BRIDGE_HOME is a symlink to the pid file's
                    real parent (`.resolve()` follows the symlink)

The validator function is loaded fresh per case via importlib so each case
gets the env it actually wants — module-level `Path(os.environ.get(...))`
would otherwise cache the first case's values across the whole test run.
"""

from __future__ import annotations

import importlib
import importlib.util
import logging
import os
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
WATCHDOG_PATH = REPO_ROOT / "bridge-watchdog-silence.py"


def _load_watchdog_module() -> Any:
    """Re-import the watchdog module so module-level env reads pick up the
    current test's `BRIDGE_HOME` / `BRIDGE_DAEMON_PID_FILE`."""
    # Use a unique module name each call so importlib doesn't return a
    # cached module with stale env-derived globals.
    mod_name = f"bridge_watchdog_silence_under_test_{len(sys.modules)}"
    spec = importlib.util.spec_from_file_location(mod_name, WATCHDOG_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not build import spec for {WATCHDOG_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = module
    spec.loader.exec_module(module)
    return module


def _set_env(home: str | None, pid_file: str | None) -> None:
    """Set or unset the two env vars the watchdog reads at import time."""
    for key, value in (("BRIDGE_HOME", home), ("BRIDGE_DAEMON_PID_FILE", pid_file)):
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


def _capture_validate(module: Any) -> tuple[int | None, str]:
    """Run `_validate_cross_home()` with a captured logger and return
    `(exit_code, error_log_text)`. `exit_code` is None on the no-exit path."""
    handler_records: list[logging.LogRecord] = []

    class ListHandler(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            handler_records.append(record)

    handler = ListHandler(level=logging.ERROR)
    module.log.addHandler(handler)
    try:
        try:
            module._validate_cross_home()
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
            text = "\n".join(r.getMessage() for r in handler_records if r.levelno >= logging.ERROR)
            return code, text
        return None, ""
    finally:
        module.log.removeHandler(handler)


def case_cross_home_refused() -> None:
    """(1) BRIDGE_HOME=/tmp/<a>, pid file under /tmp/<b> -> SystemExit(2)."""
    with tempfile.TemporaryDirectory(prefix="agb-test-home-") as home, \
         tempfile.TemporaryDirectory(prefix="agb-test-state-") as elsewhere:
        pid_file = Path(elsewhere) / "daemon.pid"
        pid_file.write_text("99999\n", encoding="utf-8")
        _set_env(home=home, pid_file=str(pid_file))
        module = _load_watchdog_module()
        code, log_text = _capture_validate(module)
    assert code == 2, f"expected SystemExit(2), got {code!r}"
    assert "refusing to run" in log_text, f"missing error log; got: {log_text!r}"
    assert "BRIDGE_DAEMON_PID_FILE" in log_text, f"log missing var name: {log_text!r}"


def case_same_home_accepted() -> None:
    """(2) pid file under BRIDGE_HOME -> no exit."""
    with tempfile.TemporaryDirectory(prefix="agb-test-home-") as home:
        state_dir = Path(home) / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        pid_file = state_dir / "daemon.pid"
        pid_file.write_text("99999\n", encoding="utf-8")
        _set_env(home=home, pid_file=str(pid_file))
        module = _load_watchdog_module()
        code, _ = _capture_validate(module)
    assert code is None, f"unexpected exit on same-home config: code={code!r}"


def case_defaults_accepted() -> None:
    """(3) Both vars unset -> defaults resolve consistently. The watchdog's
    default `BRIDGE_DAEMON_PID_FILE` is `BRIDGE_STATE_DIR/daemon.pid` which is
    `BRIDGE_HOME/state/daemon.pid` — always under home by construction."""
    _set_env(home=None, pid_file=None)
    # Do NOT touch the live ~/.agent-bridge tree; the validator only does a
    # path-prefix check via `.resolve()`. Default `Path.home() / ".agent-bridge"`
    # may or may not exist on the test host; `.resolve()` returns the absolute
    # path either way.
    module = _load_watchdog_module()
    code, _ = _capture_validate(module)
    assert code is None, f"unexpected exit on default config: code={code!r}"


def case_symlink_followed() -> None:
    """(4) BRIDGE_HOME is a symlink to a tmp dir; pid file lives under the
    symlink target. `.resolve()` on both sides should make them equal. We
    point BRIDGE_HOME at the symlink and the pid file at the underlying
    real-path so the naive (non-resolving) comparison would fail. With
    `.resolve()` it succeeds."""
    with tempfile.TemporaryDirectory(prefix="agb-test-real-") as real_home_str, \
         tempfile.TemporaryDirectory(prefix="agb-test-link-parent-") as link_parent_str:
        real_home = Path(real_home_str)
        link_parent = Path(link_parent_str)
        symlink_home = link_parent / "home-symlink"
        os.symlink(real_home, symlink_home)
        state_dir = real_home / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        pid_file = state_dir / "daemon.pid"
        pid_file.write_text("99999\n", encoding="utf-8")
        # BRIDGE_HOME points at the symlink path; pid file at the real path.
        _set_env(home=str(symlink_home), pid_file=str(pid_file))
        module = _load_watchdog_module()
        code, log_text = _capture_validate(module)
    assert code is None, (
        f"symlinked BRIDGE_HOME should be accepted after .resolve(); "
        f"got code={code!r} log={log_text!r}"
    )


def main() -> int:
    cases = [
        ("cross-home refused", case_cross_home_refused),
        ("same-home accepted", case_same_home_accepted),
        ("defaults accepted", case_defaults_accepted),
        ("symlink followed", case_symlink_followed),
    ]
    failures = 0
    for label, fn in cases:
        try:
            fn()
        except AssertionError as exc:
            failures += 1
            print(f"[smoke][fail] {label}: {exc}", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001 — surface unexpected errors as failures
            failures += 1
            print(f"[smoke][fail] {label}: unexpected {type(exc).__name__}: {exc}", file=sys.stderr)
        else:
            print(f"[smoke][pass] {label}")
    total = len(cases)
    print(f"\n[smoke] watchdog-silence cross-home: {total - failures} pass, {failures} fail")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
