#!/usr/bin/env python3
"""Symlink-safe sudo read for $workdir/CLAUDE.md (issue #1151 r3).

Background
----------
Under linux-user isolation v2 (Step A complete), the workdir is owned by
the isolated UID. Earlier sudo paths in
``bridge_ensure_project_claude_guidance`` read ``$workdir/CLAUDE.md``
with ``bridge_linux_sudo_root cat "$claude_file" >"$_src_tmp"`` after a
``test -f`` probe. Both follow symlinks. A cooperating agent UID can
race the controller and swap ``$workdir/CLAUDE.md`` for a symlink to a
root-readable secret (any path the controller's sudoers entry permits
``cat`` on); the controller-side sudo cat then reads the secret and the
follow-on render writes the captured content into a fresh regular
``CLAUDE.md`` owned by the isolated UID — i.e., a one-shot read of
root-only material laundered into the agent's workdir.

Fix
---
Open the path with ``os.O_NOFOLLOW`` so a symlink trips ``ELOOP`` /
``OSError`` immediately, then ``fstat`` the descriptor and require
``stat.S_ISREG``. The descriptor is the file we ``stat``'d, so there is
no TOCTOU window between the regular-file check and the read.

Exit codes (consumed by ``bridge_ensure_project_claude_guidance``)
------------------------------------------------------------------
* ``0``  — content streamed to stdout; safe to capture.
* ``10`` — target does not exist; caller should fall through to the
  fresh-render path (no existing content to merge).
* ``11`` — refused (symlink, ELOOP, permission, other ``OSError``).
  Caller MUST NOT proceed with the sudo write — log warning + bail.
* ``12`` — opened but ``fstat`` says not a regular file (directory,
  socket, FIFO, char/block device). Same handling as ``11``.

Invoke as a separate file (NOT heredoc-stdin) so footgun #11
(Bash 5.3.9 ``read_comsub`` / ``heredoc_write`` deadlock) cannot trip
this helper. The chosen invocation form is::

    bridge_linux_sudo_root python3 lib/skills-helpers/claude-md-safe-read.py \
        "$claude_file" >"$_src_tmp"

``bridge_linux_sudo_root`` does NOT shell through ``bash -c`` (see
``lib/bridge-agents.sh::bridge_linux_sudo_root``), so the deadlock class
does not apply here even if the body were heredoc-stdin — but extracting
to a standalone helper is the project-wide pattern (see
``lib/upgrade-helpers/``, ``lib/cron-helpers/``, ``lib/daemon-helpers/``)
and avoids adding a new ``.lint-heredoc-baseline.tsv`` row.
"""

from __future__ import annotations

import os
import stat
import sys


def _refuse(message: str, rc: int) -> None:
    sys.stderr.write(f"claude-md-safe-read: {message}\n")
    sys.exit(rc)


def main(argv: list[str]) -> None:
    if len(argv) != 2:
        _refuse(f"usage: {argv[0]} <path>", 64)

    path = argv[1]

    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        # Distinguishable "no file" signal so the caller takes the
        # fresh-render path instead of bailing.
        sys.exit(10)
    except OSError as exc:
        # ELOOP (symlink hit) lands here, as do EACCES/EPERM and any
        # other open-time failure. Fail closed.
        _refuse(f"refused open: {exc}", 11)

    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            _refuse(f"not a regular file: mode=0o{stat.S_IMODE(st.st_mode):o}", 12)

        # Stream to stdout in fixed-size chunks. The caller redirects
        # stdout to a controller-owned mktemp file, so this never
        # accumulates the full payload in Python memory.
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
    finally:
        os.close(fd)

    sys.stdout.buffer.flush()
    sys.exit(0)


if __name__ == "__main__":
    main(sys.argv)
