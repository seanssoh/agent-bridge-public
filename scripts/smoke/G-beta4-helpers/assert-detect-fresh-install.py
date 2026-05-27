#!/usr/bin/env python3
"""G-beta4 T8 / T9 — detect_fresh_install precedence + pending TTL.

Usage:
  assert-detect-fresh-install.py <repo-root> <state-dir> <home-root>

Exercises ``bridge-watchdog.detect_fresh_install`` directly across the
r2 decision matrix (codex r1 BLOCKING #1 fix):

  * Case A (complete-marker precedence): pending marker present AND
    complete marker present → fresh_install=False. The complete
    marker wins — a previously-fresh install that has since completed
    onboarding must not regress to priority=low forever.

  * Case B (SESSION-TYPE auto-detect): no markers, SESSION-TYPE.md
    reports ``Onboarding State: complete`` → fresh_install=False even
    when the home mtime would otherwise place the agent inside the
    fresh-install window. The watchdog cannot get stuck on
    fresh_install=True for an agent whose operator has actually
    finished onboarding but where the state-dir complete marker is
    missing.

  * Case C (pending TTL active): pending marker written within the
    last hour → fresh_install=True. Standard fresh-install path.

  * Case D (pending TTL expired): pending marker written 25h ago,
    SESSION-TYPE.md NOT complete, agent home mtime old →
    fresh_install=False. The brief's BLOCKING #1 closure: a stale
    pending marker no longer holds the install at priority=low.

  * Case E (pending TTL active + SESSION-TYPE complete): the
    SESSION-TYPE.md auto-detect runs BEFORE the pending marker branch,
    so a complete SESSION-TYPE reading wins over a still-fresh
    pending marker. Operator may have edited SESSION-TYPE.md by hand
    without removing the marker.
"""
import importlib.util
import os
import sys
import time
from pathlib import Path


def _load_watchdog(repo_root: Path):
    """Import bridge-watchdog.py (which has a hyphen, so importlib
    is required). Registers in sys.modules BEFORE exec_module to
    appease the dataclass machinery on Python 3.9 (which looks up the
    declaring module via ``sys.modules[cls.__module__]`` and crashes
    on KeyError otherwise — pre-3.10 dataclasses bug)."""
    src = repo_root / "bridge-watchdog.py"
    spec = importlib.util.spec_from_file_location("bridge_watchdog_under_test", src)
    if spec is None or spec.loader is None:
        raise SystemExit(f"FAIL: could not import {src}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["bridge_watchdog_under_test"] = module
    spec.loader.exec_module(module)
    return module


def _setup_agent_dirs(home_root: Path, state_dir: Path, agent: str) -> Path:
    agent_home = home_root / agent
    agent_state = state_dir / "agents" / agent
    agent_home.mkdir(parents=True, exist_ok=True)
    agent_state.mkdir(parents=True, exist_ok=True)
    return agent_home


def _write_marker(state_dir: Path, agent: str, name: str, written_ts: int):
    target = state_dir / "agents" / agent / name
    target.write_text(
        f"agent={agent}\nwritten={written_ts}\nreason=test\n",
        encoding="utf-8",
    )


def _write_session_type(agent_home: Path, state: str):
    (agent_home / "SESSION-TYPE.md").write_text(
        f"# Session Type\n- Session Type: admin\n- Onboarding State: {state}\n",
        encoding="utf-8",
    )


def main():
    if len(sys.argv) != 4:
        print(
            "usage: assert-detect-fresh-install.py <repo-root> <state-dir> <home-root>",
            file=sys.stderr,
        )
        sys.exit(2)
    repo_root = Path(sys.argv[1]).resolve()
    state_dir = Path(sys.argv[2]).resolve()
    home_root = Path(sys.argv[3]).resolve()

    state_dir.mkdir(parents=True, exist_ok=True)
    home_root.mkdir(parents=True, exist_ok=True)

    # Force a known TTL window so the test is deterministic.
    os.environ["BRIDGE_WATCHDOG_FRESH_INSTALL_PENDING_TTL_SECS"] = "3600"
    os.environ["BRIDGE_WATCHDOG_FRESH_INSTALL_WINDOW_SECS"] = "600"

    module = _load_watchdog(repo_root)
    detect_fresh_install = module.detect_fresh_install

    now_ts = int(time.time())

    # ---- Case A: complete marker present alongside pending → False
    agent_a = "case_a_complete_wins"
    home_a = _setup_agent_dirs(home_root, state_dir, agent_a)
    _write_marker(state_dir, agent_a, "onboarding-pending", now_ts - 60)
    _write_marker(state_dir, agent_a, "onboarding-complete", now_ts - 30)
    result_a = detect_fresh_install(state_dir, agent_a, home_a)
    assert result_a is False, (
        f"Case A FAIL: complete marker present should suppress fresh; "
        f"got {result_a}"
    )

    # ---- Case B: no markers, SESSION-TYPE.md complete, recent mtime → False
    agent_b = "case_b_session_complete"
    home_b = _setup_agent_dirs(home_root, state_dir, agent_b)
    _write_session_type(home_b, "complete")
    # Touch home to fresh so the mtime branch would otherwise vote True.
    os.utime(home_b, (now_ts, now_ts))
    result_b = detect_fresh_install(state_dir, agent_b, home_b)
    assert result_b is False, (
        f"Case B FAIL: SESSION-TYPE complete should suppress fresh "
        f"even with recent mtime; got {result_b}"
    )

    # ---- Case C: pending marker within TTL → True
    agent_c = "case_c_pending_active"
    home_c = _setup_agent_dirs(home_root, state_dir, agent_c)
    _write_session_type(home_c, "pending")
    _write_marker(state_dir, agent_c, "onboarding-pending", now_ts - 60)
    result_c = detect_fresh_install(state_dir, agent_c, home_c)
    assert result_c is True, (
        f"Case C FAIL: pending marker within TTL should be fresh; "
        f"got {result_c}"
    )

    # ---- Case D: pending marker expired → False (no SESSION-TYPE complete, old mtime)
    agent_d = "case_d_pending_expired"
    home_d = _setup_agent_dirs(home_root, state_dir, agent_d)
    _write_session_type(home_d, "pending")
    # Written 2h ago, TTL is 1h
    _write_marker(state_dir, agent_d, "onboarding-pending", now_ts - 7200)
    # Push mtime old enough to also be outside the fallback window.
    old_ts = now_ts - 4000
    os.utime(home_d, (old_ts, old_ts))
    result_d = detect_fresh_install(state_dir, agent_d, home_d)
    assert result_d is False, (
        f"Case D FAIL: expired pending marker (no complete signal) "
        f"should yield fresh=False; got {result_d}"
    )

    # ---- Case E: pending marker active + SESSION-TYPE complete → False
    agent_e = "case_e_pending_but_session_complete"
    home_e = _setup_agent_dirs(home_root, state_dir, agent_e)
    _write_session_type(home_e, "complete")
    _write_marker(state_dir, agent_e, "onboarding-pending", now_ts - 60)
    result_e = detect_fresh_install(state_dir, agent_e, home_e)
    assert result_e is False, (
        f"Case E FAIL: SESSION-TYPE complete must beat an active "
        f"pending marker; got {result_e}"
    )

    print("T8 + T9 PASS — fresh_install precedence + TTL across 5 cases")


if __name__ == "__main__":
    main()
