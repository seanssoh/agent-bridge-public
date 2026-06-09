#!/usr/bin/env python3
"""File-as-argv sidecar for scripts/smoke/1728-test-bind-state-path-guard.sh.

Issue #1728 (HIGH, data-loss): the `BRIDGE_A2A_ALLOW_TEST_BIND` test-bind flag
gates the loopback socket bind but NOT the A2A/rooms STATE PATH. `handoff_dir()`
resolves `BRIDGE_STATE_DIR` ahead of `BRIDGE_HOME` in both bridge_a2a_common.py
and bridge_rooms_common.py, so a throwaway test mesh that overrides only
per-node `BRIDGE_HOME` but inherits a live `BRIDGE_STATE_DIR` writes rooms.db /
reconcile.db / outbox / inbox into the LIVE state tree — clobbering real room
membership.

The fix adds a `BRIDGE_A2A_ALLOW_TEST_BIND`-gated state-path guard (symmetric to
the existing bind guard): when the flag is set AND the resolved state dir is
NOT under the active `BRIDGE_HOME`, the A2A/rooms write paths fail closed with a
clear error instead of clobbering the live tree. The flag is test-only, so the
guard can never affect a production install.

Each subcommand drives the REAL production code (the module guard + the real
`ensure_handoff_dirs` / `open_rooms` write choke points) against ISOLATED tmp
dirs, never the operator's live runtime. file-as-argv only — no heredoc-stdin
(footgun #11). Run green on /opt/homebrew/bin/bash (macOS) and Linux CI bash.

argv: <subcommand> <repo_root> <live_dir> <home_dir>
  subcommand ∈ {
    override-no-optin-prod,   # (a) override WITHOUT opt-in -> prod path, no fire
    override-with-optin-deny, # (b) override outside home + opt-in -> FAIL CLOSED
    isolated-under-home-allow,# (c) override under test home + opt-in -> allowed
    no-override-default-allow,# (d) opt-in, no override -> default home/state allow
    pre-fix-would-clobber,    # (control) guard stubbed -> proves the clobber
  }
"""
import os
import sys


def _listing(root):
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            out.append(os.path.relpath(os.path.join(dirpath, f), root))
    return sorted(out)


def _clear_env():
    for k in (
        "BRIDGE_A2A_ALLOW_TEST_BIND",
        "BRIDGE_HOME",
        "BRIDGE_STATE_DIR",
        "BRIDGE_A2A_ROOMS_DB",
        "BRIDGE_A2A_OUTBOX_DB",
        "BRIDGE_A2A_INBOX_DB",
        "BRIDGE_A2A_RECONCILE_DB",
    ):
        os.environ.pop(k, None)


def main(argv):
    if len(argv) != 5:
        print("usage: <subcommand> <repo_root> <live_dir> <home_dir>",
              file=sys.stderr)
        return 2
    sub, repo_root, live_dir, home_dir = argv[1:5]
    sys.path.insert(0, repo_root)
    import bridge_a2a_common as a2a
    import bridge_rooms_common as rooms

    os.makedirs(live_dir, exist_ok=True)
    os.makedirs(home_dir, exist_ok=True)

    if sub == "override-no-optin-prod":
        # (a) Override WITHOUT the opt-in: this is the normal production shape
        # (a configured host exports BRIDGE_STATE_DIR). The guard MUST NOT fire,
        # and the real write paths MUST work into the (live) state dir.
        _clear_env()
        os.environ["BRIDGE_HOME"] = home_dir
        os.environ["BRIDGE_STATE_DIR"] = live_dir
        a2a.guard_test_bind_state_path()
        rooms.guard_test_bind_state_path()
        a2a.ensure_handoff_dirs()
        conn = rooms.open_rooms()
        conn.close()
        wrote = _listing(live_dir)
        if any("rooms.db" in p for p in wrote):
            print("OK override-no-optin-prod")
            return 0
        print("FAIL override-no-optin-prod: prod path did not write rooms.db: %s"
              % wrote, file=sys.stderr)
        return 1

    if sub == "override-with-optin-deny":
        # (b) THE FOOTGUN: opt-in SET + BRIDGE_STATE_DIR points at a live tree
        # OUTSIDE the test BRIDGE_HOME. Both guards MUST fail closed, the real
        # write paths MUST raise, and NOTHING may be written into live_dir.
        _clear_env()
        os.environ["BRIDGE_A2A_ALLOW_TEST_BIND"] = "1"
        os.environ["BRIDGE_HOME"] = home_dir
        os.environ["BRIDGE_STATE_DIR"] = live_dir
        a2a_fired = rooms_fired = False
        try:
            a2a.guard_test_bind_state_path()
        except a2a.A2AError as e:
            a2a_fired = (e.code == "test_bind_state_outside_home")
        try:
            rooms.guard_test_bind_state_path()
        except rooms.RoomsError as e:
            rooms_fired = (e.code == "test_bind_state_outside_home")
        # Real write choke points must also fail closed.
        ensure_blocked = rooms_blocked = False
        try:
            a2a.ensure_handoff_dirs()
        except a2a.A2AError:
            ensure_blocked = True
        try:
            conn = rooms.open_rooms()
            conn.close()
        except rooms.RoomsError:
            rooms_blocked = True
        leaked = _listing(live_dir)
        if (a2a_fired and rooms_fired and ensure_blocked and rooms_blocked
                and not leaked):
            print("OK override-with-optin-deny")
            return 0
        print("FAIL override-with-optin-deny: a2a=%s rooms=%s ensure_blocked=%s "
              "rooms_blocked=%s leaked=%s"
              % (a2a_fired, rooms_fired, ensure_blocked, rooms_blocked, leaked),
              file=sys.stderr)
        return 1

    if sub == "isolated-under-home-allow":
        # (c) Correctly isolated test mesh: opt-in SET but BRIDGE_STATE_DIR is
        # UNDER the test BRIDGE_HOME. The guard MUST allow; writes land in the
        # test home, never the live tree.
        _clear_env()
        test_state = os.path.join(home_dir, "state")
        os.environ["BRIDGE_A2A_ALLOW_TEST_BIND"] = "1"
        os.environ["BRIDGE_HOME"] = home_dir
        os.environ["BRIDGE_STATE_DIR"] = test_state
        a2a.guard_test_bind_state_path()
        rooms.guard_test_bind_state_path()
        a2a.ensure_handoff_dirs()
        conn = rooms.open_rooms()
        conn.close()
        wrote = _listing(home_dir)
        leaked = _listing(live_dir)
        if any("rooms.db" in p for p in wrote) and not leaked:
            print("OK isolated-under-home-allow")
            return 0
        print("FAIL isolated-under-home-allow: wrote=%s leaked=%s"
              % (wrote, leaked), file=sys.stderr)
        return 1

    if sub == "no-override-default-allow":
        # (d) opt-in SET, NO BRIDGE_STATE_DIR override → state_dir() defaults to
        # BRIDGE_HOME/state (under home) → guard allows. Confirms the opt-in
        # alone never blocks a default-shaped test mesh.
        _clear_env()
        os.environ["BRIDGE_A2A_ALLOW_TEST_BIND"] = "1"
        os.environ["BRIDGE_HOME"] = home_dir
        a2a.guard_test_bind_state_path()
        rooms.guard_test_bind_state_path()
        a2a.ensure_handoff_dirs()
        conn = rooms.open_rooms()
        conn.close()
        wrote = _listing(home_dir)
        if any("rooms.db" in p for p in wrote):
            print("OK no-override-default-allow")
            return 0
        print("FAIL no-override-default-allow: wrote=%s" % wrote, file=sys.stderr)
        return 1

    if sub == "pre-fix-would-clobber":
        # (control) Neuter the guard (simulate the PRE-fix code) and confirm the
        # footgun WOULD write rooms.db into the live tree — proves the guard is
        # what prevents the clobber, not some unrelated change.
        _clear_env()
        a2a.guard_test_bind_state_path = lambda: None
        rooms.guard_test_bind_state_path = lambda: None
        os.environ["BRIDGE_A2A_ALLOW_TEST_BIND"] = "1"
        os.environ["BRIDGE_HOME"] = home_dir
        os.environ["BRIDGE_STATE_DIR"] = live_dir
        conn = rooms.open_rooms()
        conn.close()
        a2a.ensure_handoff_dirs()
        leaked = _listing(live_dir)
        if any("rooms.db" in p for p in leaked):
            print("OK pre-fix-would-clobber")
            return 0
        print("FAIL pre-fix-would-clobber: nothing leaked, repro invalid: %s"
              % leaked, file=sys.stderr)
        return 1

    print("unknown subcommand: %s" % sub, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
