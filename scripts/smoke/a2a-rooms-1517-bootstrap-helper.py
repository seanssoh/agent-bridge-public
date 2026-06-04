#!/usr/bin/env python3
"""Helper for the a2a-rooms-1517-bootstrap smoke.

File-as-argv sidecar (not a heredoc fed into `python3 -`) so the smoke shell
never trips the Bash 5.3.9 heredoc-stdin deadlock (footgun #11). Imports the
real rooms module from the repo root so the smoke exercises the canonical
bootstrap code (`maybe_bootstrap_rooms_db`, `canonical_rooms_db_path`,
`_caller_owns_canonical_controller_location`, `_controller_uid`).

Subcommands (argv[1]):
  bootstrap                 run maybe_bootstrap_rooms_db(); print
                            "created=<bool> canon_exists=<bool> "
                            "controller_is_me=<bool>"
  regime                    print "regime=<r>" (resolve_os_actor regime)
  bootstrap-then-regime     print "before=<r> created=<bool> after=<r>" — the
                            negative control proving the bootstrap flips the
                            controller UNRESOLVED -> CONTROLLER on a fresh host
  canon-path                print the canonical rooms.db path (ignores
                            BRIDGE_A2A_ROOMS_DB)
  controller-uid            print "controller_uid=<int|none>" (the rooms-DB
                            owner anchor)
  path-exists <path>        exit 0 iff <path> exists
  file-mode <path>          print the octal file mode (e.g. 600)
  file-owner-is-me <path>   exit 0 iff os.stat(<path>).st_uid == os.getuid()
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import bridge_rooms_common as rooms  # noqa: E402


def cmd_bootstrap() -> int:
    created = rooms.maybe_bootstrap_rooms_db()
    canon = rooms.canonical_rooms_db_path()
    cu = rooms._controller_uid()
    controller_is_me = cu is not None and cu == os.getuid()
    print(f"created={created} canon_exists={canon.exists()} "  # noqa: raw-pathlib-controller-only
          f"controller_is_me={controller_is_me}")
    return 0


def cmd_regime() -> int:
    """Print the resolved actor-auth regime for the current process env.

    Output: "regime=<r>". Used by the negative control to prove the bootstrap
    is what flips the controller from UNRESOLVED -> CONTROLLER on a fresh host.
    """
    a = rooms.resolve_os_actor(None)
    print(f"regime={a.regime}")
    return 0


def cmd_bootstrap_then_regime() -> int:
    """Negative control / teeth: print the controller's regime BEFORE and AFTER
    the bootstrap on a fresh canonical host.

    BEFORE (no rooms.db): `_controller_uid()` cannot anchor → the controller
    falls through to UNRESOLVED on an iso host (the #1517 bug — what `create`
    would raise as actor_unresolved). AFTER `maybe_bootstrap_rooms_db()`: the
    canonical controller-owned db exists → `_controller_uid()` anchors →
    CONTROLLER. Output:
      "before=<regime> created=<bool> after=<regime>".
    """
    before = rooms.resolve_os_actor(None).regime
    created = rooms.maybe_bootstrap_rooms_db()
    after = rooms.resolve_os_actor(None).regime
    print(f"before={before} created={created} after={after}")
    return 0


def cmd_canon_path() -> int:
    print(str(rooms.canonical_rooms_db_path()))
    return 0


def cmd_controller_uid() -> int:
    cu = rooms._controller_uid()
    print(f"controller_uid={'none' if cu is None else cu}")
    return 0


def cmd_path_exists(path: str) -> int:
    return 0 if os.path.exists(path) else 1


def cmd_file_mode(path: str) -> int:
    print(format(os.stat(path).st_mode & 0o777, "o"))
    return 0


def cmd_file_owner_is_me(path: str) -> int:
    try:
        return 0 if os.stat(path).st_uid == os.getuid() else 1
    except OSError:
        return 2


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: a2a-rooms-1517-bootstrap-helper.py <subcommand> [args]",
              file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "bootstrap":
        return cmd_bootstrap()
    if cmd == "regime":
        return cmd_regime()
    if cmd == "bootstrap-then-regime":
        return cmd_bootstrap_then_regime()
    if cmd == "canon-path":
        return cmd_canon_path()
    if cmd == "controller-uid":
        return cmd_controller_uid()
    if cmd == "path-exists":
        return cmd_path_exists(rest[0])
    if cmd == "file-mode":
        return cmd_file_mode(rest[0])
    if cmd == "file-owner-is-me":
        return cmd_file_owner_is_me(rest[0])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
