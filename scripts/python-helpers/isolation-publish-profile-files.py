#!/usr/bin/env python3
"""#1520c — TOCTOU-safe root publish of the six Claude identity profile
files to ``ab-agent-<a>:0660`` on a first-time ``agent create --isolate``.

This is the privileged inner half of
``bridge_isolation_v2_publish_workdir_profile_files`` (lib/bridge-isolation-v2.sh).
It is invoked AS ROOT (``bridge_linux_sudo_root python3 <this> ...``) AFTER
``bridge_linux_prepare_agent_isolation``'s ``chown -R <iso-uid> <workdir>``.
At that point the iso UID OWNS the workdir directory and every entry in it,
so it can rename/replace a profile basename with a symlink (or any other
inode) at any instant. A path-based ``chgrp``/``chmod`` — even one guarded
by a prior ``test -h`` — is therefore racy: the iso UID can swap
``SOUL.md`` for ``SOUL.md -> /etc/shadow`` BETWEEN the symlink check and
the root mutation, redirecting the root ``chgrp``/``chmod`` onto an
external target it does not own (CVE-class TOCTOU).

The fix is to NEVER re-resolve a profile pathname after deciding to mutate
it. We:

  1. ``open(workdir, O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`` to get a directory
     fd. The workdir's PARENT (``$BRIDGE_DATA_ROOT/agents/`` or the home
     root) is controller-owned, so the iso UID cannot swap the workdir
     directory inode itself — only entries INSIDE it. ``O_NOFOLLOW`` also
     refuses a symlinked workdir.
  2. For each basename, ``openat(dir_fd, name, O_RDONLY|O_NOFOLLOW|O_NONBLOCK)``.
     ``O_NOFOLLOW`` makes the open FAIL with ``ELOOP`` if the final
     component is a symlink — a planted ``CLAUDE.md -> /tmp/evil`` is
     refused, never opened. ``O_NONBLOCK`` avoids blocking on a FIFO; a
     non-regular inode is rejected after ``fstat``.
  3. ``fstat`` the fd: it MUST be a regular file owned by the iso UID
     (``st_uid == <iso-uid>``). A non-regular inode, or one owned by
     anyone else (a hardlink to a file the iso UID does not own cannot be
     created under the default ``fs.protected_hardlinks``; an unexpected
     owner is refused defensively regardless).
  4. ``fchown(fd, -1, gid)`` then ``fchmod(fd, 0o660)`` — both operate on
     the OPEN FILE DESCRIPTION, which is bound to the inode opened in (2).
     The iso UID can rename the path all it likes afterwards; our fd still
     points at the verified regular file, so there is no second
     path-resolution for it to race.

Idempotent: a file already at ``<gid>:0660`` is skipped (no syscall).

Output contract (consumed by the bash caller): one TAB-separated line per
basename on stdout — ``<status>\t<basename>\t<detail>``. Statuses:
``published`` (mutated), ``ok-nochange`` (already at contract),
``absent`` (basename not present — fine on a partial tree),
``refused-symlink`` (``O_NOFOLLOW`` rejected a symlinked basename),
``refused-nonregular`` (FIFO/dir/device/socket), ``refused-owner``
(``st_uid`` is not the iso UID), ``mutate-failed`` (fchown/fchmod raised;
``detail`` = ``<op>:<errno>``). Exit 0 for any per-file outcome (all
non-fatal — the bash caller warns/audits per non-``published``/``ok``/
``absent`` line and create still succeeds). Exit 2 ONLY for a fatal setup
error (unknown group, workdir not openable) — the caller then emits a
single non-fatal warn + audit row.

Footgun #11: argv-only; no stdin/heredoc. macOS-safe (``O_NOFOLLOW``,
``fchown``, ``fchmod`` all exist on BSD) so the smoke exercises the real
fd-based path off Linux via ``bridge_linux_sudo_root``'s direct
fall-through.
"""
import errno
import grp
import os
import pwd
import stat
import sys


def _emit(status: str, name: str, detail: str = "") -> None:
    # TAB-separated, single line. Basenames are the six fixed *.md names
    # (no tabs/newlines), so this is unambiguous for the bash `read` loop.
    sys.stdout.write(f"{status}\t{name}\t{detail}\n")


def _publish_one(dir_fd: int, name: str, gid: int, mode: int, want_uid):
    """Open ``name`` relative to ``dir_fd`` with O_NOFOLLOW, verify it is a
    regular file owned by the iso UID, then fchown/fchmod the FD."""
    try:
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=dir_fd,
        )
    except FileNotFoundError:
        return ("absent", "")
    except OSError as exc:
        # ELOOP: final component is a symlink and O_NOFOLLOW refused it.
        # (Linux reports ELOOP; some BSDs report EMLINK/EFTYPE — treat any
        # "is a link" style refusal as a symlink refusal so the planted-
        # redirect case is fenced uniformly.)
        if exc.errno in (errno.ELOOP, getattr(errno, "EMLINK", -1),
                         getattr(errno, "EFTYPE", -1)):
            return ("refused-symlink", "")
        return ("mutate-failed", f"open:{exc.errno}")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return ("refused-nonregular", oct(stat.S_IFMT(st.st_mode)))
        if want_uid is not None and st.st_uid != want_uid:
            return ("refused-owner", str(st.st_uid))
        # Idempotent: already at the contract → no syscall.
        if st.st_gid == gid and stat.S_IMODE(st.st_mode) == mode:
            return ("ok-nochange", "")
        try:
            os.fchown(fd, -1, gid)
        except OSError as exc:
            return ("mutate-failed", f"fchown:{exc.errno}")
        try:
            os.fchmod(fd, mode)
        except OSError as exc:
            return ("mutate-failed", f"fchmod:{exc.errno}")
        return ("published", "")
    finally:
        os.close(fd)


def main(argv) -> int:
    if len(argv) < 5:
        sys.stderr.write(
            "usage: isolation-publish-profile-files.py "
            "<workdir> <group> <octal-mode> <iso-user> <basename> [<basename>...]\n"
        )
        return 2
    workdir = argv[1]
    group = argv[2]
    mode_raw = argv[3]
    iso_user = argv[4]
    basenames = argv[5:]

    try:
        mode = int(mode_raw, 8)
    except ValueError:
        sys.stderr.write(f"fatal: bad octal mode {mode_raw!r}\n")
        return 2

    try:
        gid = grp.getgrnam(group).gr_gid
    except KeyError:
        sys.stderr.write(f"fatal: group not found: {group}\n")
        return 2

    # Expected owner of every profile file after prepare's `chown -R`.
    # Used as a defence-in-depth `st_uid` check; absence (unknown user)
    # downgrades to "skip the owner check" rather than refusing everything.
    want_uid = None
    if iso_user:
        try:
            want_uid = pwd.getpwnam(iso_user).pw_uid
        except KeyError:
            want_uid = None

    # The workdir's parent is controller-owned, so the iso UID cannot swap
    # the workdir inode itself — only entries within it. O_NOFOLLOW also
    # refuses a symlinked workdir. O_DIRECTORY ensures we really have a dir.
    try:
        dir_fd = os.open(
            workdir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        )
    except OSError as exc:
        sys.stderr.write(f"fatal: cannot open workdir {workdir!r}: {exc.errno}\n")
        return 2

    try:
        for name in basenames:
            # Defence: reject any basename that is not a bare filename
            # (no path separators) so a caller bug cannot escape the dir_fd.
            if not name or "/" in name or name in (".", ".."):
                _emit("refused-nonregular", name, "not-a-bare-basename")
                continue
            status, detail = _publish_one(dir_fd, name, gid, mode, want_uid)
            _emit(status, name, detail)
    finally:
        os.close(dir_fd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
