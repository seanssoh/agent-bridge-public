#!/usr/bin/env python3
"""PTY harness for the #1367 sealed-paste operator-terminal receive smoke.

Drives ``bridge-auth.py … receive`` (or ``bridge-auth.sh … receive``)
under a real pseudo-terminal so the smoke can exercise the echo-off
``/dev/tty`` read path without an interactive operator. The token is
typed into the pty master AFTER the child prints its prompt; because the
read is echo-off, the token must NOT appear in the pty master capture —
which is the proxy for "what a transcript / terminal scrollback would
see".

File-as-argv (NOT heredoc-stdin to a subprocess) so the smoke stays
clean under ``scripts/lint-heredoc-ban.sh`` — this helper is the
standalone extraction the footgun-#11 discipline requires.

Usage:
    1367-auth-sealed-paste-pty-helper.py <capture-out> <token> -- <cmd...>

  <capture-out>  path to write the raw pty-master capture bytes
  <token>        the dummy token to type after the prompt appears
  <cmd...>       the receive command to run under the pty

Exit code: the child's exit status (0 on a successful receive).
Prints ``CANARY_IN_PTY_CAPTURE=YES|NO`` on stdout so the caller can
assert echo-off without re-deriving the token.
"""

from __future__ import annotations

import os
import pty
import select
import sys
import time


def main(argv: list[str]) -> int:
    if "--" not in argv:
        sys.stderr.write("usage: <capture-out> <token> -- <cmd...>\n")
        return 2
    sep = argv.index("--")
    head = argv[:sep]
    cmd = argv[sep + 1 :]
    if len(head) != 2 or not cmd:
        sys.stderr.write("usage: <capture-out> <token> -- <cmd...>\n")
        return 2
    capture_out, token = head

    pid, fd = pty.fork()
    if pid == 0:
        # Child — exec the receive command. Its controlling terminal is
        # the pty slave, so /dev/tty resolves to it.
        os.execvp(cmd[0], cmd)
        os._exit(127)  # unreachable

    out = b""
    wrote = False
    deadline = time.time() + 15
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            out += data
            if not wrote and b"paste" in out.lower():
                os.write(fd, (token + "\n").encode("utf-8"))
                wrote = True
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    try:
        os.close(fd)
    except OSError:
        pass

    with open(capture_out, "wb") as fh:
        fh.write(out)

    leaked = token.encode("utf-8") in out
    sys.stdout.write("CANARY_IN_PTY_CAPTURE=%s\n" % ("YES" if leaked else "NO"))
    sys.stdout.flush()

    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
