#!/usr/bin/env python3
"""#1766 smoke helper: assert a path's group + mode against an expectation.

Argv-only (footgun #11 — no stdin/heredoc). Usage:

    assert-mode-group.py <path> <expect-group> <expect-mode-octal>

`<expect-group>` is matched against the path's group NAME (resolved via
`grp.getgrgid`). `<expect-mode-octal>` is the low 12 bits compared after
normalizing both sides through int(...,8) so `0640` and `640` parse the
same. Prints `ok` and exits 0 on a match; prints `mismatch ...` and exits
1 otherwise. macOS-safe (uses os.stat, not `stat -c/-f`), so the smoke can
read the setgid bit portably.
"""
import grp
import os
import stat
import sys


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(
            "usage: assert-mode-group.py <path> <expect-group> "
            "<expect-mode-octal>\n"
        )
        return 2
    path, want_group, want_mode_raw = argv[1], argv[2], argv[3]
    try:
        want_mode = int(want_mode_raw, 8)
    except ValueError:
        sys.stderr.write(f"bad octal mode {want_mode_raw!r}\n")
        return 2
    try:
        st = os.lstat(path)
    except OSError as exc:
        sys.stderr.write(f"mismatch: cannot stat {path}: {exc}\n")
        return 1
    cur_mode = stat.S_IMODE(st.st_mode)
    try:
        cur_group = grp.getgrgid(st.st_gid).gr_name
    except KeyError:
        cur_group = str(st.st_gid)
    if cur_group != want_group:
        sys.stderr.write(
            f"mismatch: {path} group={cur_group} (want {want_group})\n"
        )
        return 1
    if cur_mode != want_mode:
        sys.stderr.write(
            f"mismatch: {path} mode={oct(cur_mode)} (want {oct(want_mode)})\n"
        )
        return 1
    sys.stdout.write("ok\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
