#!/usr/bin/env python3
"""#1533 — TOCTOU-safe root normalize of an isolated agent's writable
content subtrees (``home/``, ``workdir/``, ``runtime/``, ``logs/``) to
``ab-agent-<a>:0660`` files / ``ab-agent-<a>:2770`` dirs on a first-time
``agent create --isolate``.

This is the privileged inner half of
``bridge_isolation_v2_publish_content_tree`` (lib/bridge-isolation-v2.sh)
and the recursive generalization of the per-file
``isolation-publish-profile-files.py`` (PR-C, #1520c). It is invoked AS
ROOT (``bridge_linux_sudo_root python3 <this> ...``) AFTER
``bridge_linux_prepare_agent_isolation``'s ``chown -R <iso-uid> <root>``.

Why it must exist (the #1533 bug). The create-path #1506 normalize
(``bridge_isolation_v2_chgrp_setgid_recursive``) runs its per-entry
chgrp/chmod DIRECT-FIRST as the controller. On a FIRST
``agent create --isolate`` the controller process that invoked
``agent create`` carries a STALE supplementary-group cache that excludes
the just-created ``ab-agent-<a>`` group (KNOWN_ISSUES §28 — a live
process never refreshes its supp-group set after ``usermod -aG``).
Prepare then ``chown -R``'d the subtree to the iso UID and flipped the
top dir to ``2770 ab-agent-<a>``, so the stale controller cannot ENTER
it: ``find … -exec`` reaches ZERO files, returns 0, and the per-entry
mutations silently no-op. The result is every pre-scaffolded file
stranded at ``iso-uid:<controller-group> 0600`` (the watchdog then flags
a profile-drift ``scan_error``, and Claude session boot can be blocked
because the iso process cannot group-read its own identity files). Only
the narrow PR-C profile publish (always-root, fd-based) escaped this —
for its six basenames. This helper closes the residual for the WHOLE
content tree.

Why a root recursive walk is TOCTOU-dangerous, and how we fence it.
After prepare's ``chown -R <iso-uid>``, the iso UID OWNS every entry in
the subtree and can rename/replace any inode for a symlink (or any other
inode) at any instant. A path-based ``chgrp``/``chmod`` — or a
``find -exec`` as root — is therefore racy at every node: the iso UID
can swap ``CLAUDE.md`` for ``CLAUDE.md -> /etc/shadow`` between a path
check and a path mutation, redirecting the root mutation onto an
external target it does not own (CVE-class TOCTOU, exactly what PR-C
solved per-file). At directory-walk scale the same race applies to every
descent. We never re-resolve a pathname after deciding to mutate it:

  1. The TOP root (``home``/``workdir``/``runtime``/``logs``) is opened
     ``open(root, O_RDONLY|O_DIRECTORY|O_NOFOLLOW)``. Its PARENT (the
     per-agent root ``$BRIDGE_AGENT_ROOT_V2/<a>``) is controller-owned
     ``2750``, so the iso UID cannot swap the root directory inode
     itself — only entries inside it. ``O_NOFOLLOW`` also refuses a
     symlinked root.
  2. Every directory descent uses
     ``openat(parent_fd, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK)``.
     ``O_NOFOLLOW`` refuses a planted ``subdir -> /etc`` redirect (the
     open fails with ELOOP, the entry is recorded ``refused-symlink``
     and NOT descended into). ``O_DIRECTORY`` ensures we really have a
     directory.
  3. Every regular-file mutation uses
     ``openat(parent_fd, name, O_RDONLY|O_NOFOLLOW|O_NONBLOCK)`` then
     ``fstat`` (regular file + ``st_uid == <iso-uid>``), then
     ``fchown(fd, -1, gid)`` / ``fchmod(fd, 0o660)`` on the OPEN FD.
     The iso UID can rename the path afterwards; our fd still points at
     the verified inode, so there is no second path resolution to race.
  4. Directory metadata (group + setgid mode 2770) is applied with
     ``fchown(dir_fd, -1, gid)`` / ``fchmod(dir_fd, 0o2770)`` on the
     verified directory fd — never a path-based ``chmod`` of the dir.
  5. We walk with an EXPLICIT fd stack (iterative, not ``os.walk``)
     because ``os.walk`` re-resolves paths and follows directory fds it
     did not open with ``O_NOFOLLOW``. Every fd we open we close.

Owner gate. Every entry MUST be owned by the iso UID (``st_uid ==
want_uid``). A non-regular / non-directory inode, a symlink, or an entry
owned by anyone else is REFUSED (recorded + skipped), never mutated.
This is the same defence-in-depth check PR-C uses: after prepare's
``chown -R`` every legitimate entry is iso-owned, so an unexpected owner
is anomalous and must not be touched by a root chgrp/chmod.

Excludes. ``--exclude-subdir <name>`` prunes the CONTENTS of a named
top-level subdir from the walk while still normalizing the subdir node
itself — this mirrors the bash recursive helper's treatment of the v3
channel-state dirs (``.teams``/``.ms365``/``.discord``/``.telegram``/
``.mattermost``) whose dotenv/state files must stay
``iso-uid:ab-agent-<a> 0600`` (NOT republished to 0660). The exclude is
matched against the basename of a TOP-LEVEL entry only (a defence so a
nested same-named dir deeper in the tree is still normalized).

``--exclude-name <basename>`` skips a TOP-LEVEL entry ENTIRELY (neither
chgrp nor chmod, and — for a directory — no descent). This carries the
files whose 0600/owner contract must NOT be relaxed to the 0660 content
contract: ``HEARTBEAT.md`` (controller-owned 0600 by design — the daemon
owns it; the iso UID never reads it) and ``CHANGE-POLICY.md`` (a symlink
to the shared copy — O_NOFOLLOW would refuse it anyway, but the explicit
name-exclude avoids a per-run ``refused-symlink`` warn/audit for a known
benign link). Like ``--exclude-subdir`` it matches the basename of a
TOP-LEVEL entry only.

Exec bit preserved. A regular file's execute bits (any of u/g/o +x) are
preserved: plugin scripts under ``home/skills`` / ``.claude`` may be
executable, and a blanket ``chmod 0660`` would strip ``+x``. We compute
the target mode as ``0o660 | (current_exec_bits)`` so an executable file
lands ``0770`` (group-exec mirrors owner-exec) and a non-exec file lands
``0660``. The setgid bit on a regular file is cleared (only dirs carry
it). This matches the bash recursive helper's exec-bit-preserving
contract.

Idempotent: an entry already at the target (gid + mode) is skipped (no
chown/chmod syscall), so a re-run (reapply / a second prepare pass on an
already-published tree, or the create-path direct-first normalize having
already succeeded in the re-login case) performs zero mutations.

Output contract (consumed by the bash caller): one TAB-separated line
per NON-OK outcome (and a single trailing summary line) on stdout —
``<status>\t<relpath>\t<detail>``. Per-entry statuses:
``refused-symlink`` (``O_NOFOLLOW`` rejected a symlinked entry),
``refused-nonregular`` (block/char/socket/fifo), ``refused-owner``
(``st_uid`` is not the iso UID), ``mutate-failed`` (fchown/fchmod
raised; ``detail`` = ``<op>:<errno>``). Successful entries
(``published`` / ``ok-nochange``) are NOT emitted line-by-line to keep
the stream bounded on a large tree; the trailing
``summary\t<roots>\tpublished=<n>,ok=<n>,refused=<n>,failed=<n>`` line
carries the counts. Exit 0 for ANY per-entry outcome (all non-fatal —
the bash caller warns/audits per refusal/failure line and create still
succeeds). Exit 2 ONLY for a fatal setup error (unknown group, no
root openable) — the caller then emits a single non-fatal warn + audit
row.

Footgun #11: argv-only; no stdin/heredoc. macOS-safe (``O_NOFOLLOW``,
``fchown``, ``fchmod``, ``openat`` via ``dir_fd=`` all exist on BSD) so
the smoke exercises the real fd-based path off Linux via
``bridge_linux_sudo_root``'s direct fall-through.
"""
import argparse
import errno
import grp
import os
import stat
import sys


# A bounded guard against a pathological/hostile tree (the iso UID could
# in principle create a very deep or very wide tree between chown -R and
# this walk). The scaffold tree is shallow; this only fences an abuse.
MAX_ENTRIES = 200000
MAX_DEPTH = 64


def _emit(status, relpath, detail=""):
    # TAB-separated, single line. Relpaths may contain spaces but not
    # tabs/newlines in any real scaffold entry; we sanitize defensively.
    safe = relpath.replace("\t", "?").replace("\n", "?")
    sys.stdout.write(f"{status}\t{safe}\t{detail}\n")


_SYMLINK_ERRNOS = (
    errno.ELOOP,
    getattr(errno, "EMLINK", -1),
    getattr(errno, "EFTYPE", -1),
)


def _target_file_mode(cur_mode, base_file_mode):
    # Preserve exec bits: if the file currently has any execute bit, mirror
    # owner-exec into group-exec so a plugin script stays runnable; a file
    # with no exec bit lands at the plain base mode. setgid/setuid/sticky on
    # a regular file are dropped (only dirs carry setgid in this contract).
    exec_bits = cur_mode & 0o111
    if exec_bits:
        # owner/group/other exec all set so the iso UID + group can run it.
        return (base_file_mode | 0o110) & 0o777
    return base_file_mode & 0o777


class Walker:
    def __init__(
        self,
        gid,
        want_uid,
        dir_owner_uids,
        file_mode,
        dir_mode,
        excl_names,
        excl_basenames,
        accept_link_rel=None,
        accept_link_target=None,
    ):
        self.gid = gid
        # Strict owner gate for REGULAR FILES: after prepare's `chown -R`
        # every legitimate content file is owned by the iso UID. A file
        # owned by anyone else is anomalous and refused (never root-mutated).
        self.want_uid = want_uid
        # DIRECTORIES legitimately have two owner classes in this tree: the
        # CONTROLLER owns the container dirs it created in prepare
        # (`home`/`workdir`/`runtime`/`logs` at `controller:2770`), while the
        # iso UID owns the scaffolded subdirs (`.claude/`, `memory/`, …)
        # after `chown -R`. Accept either; refuse a dir owned by anyone else
        # (and do not descend into it). The iso UID cannot swap a
        # controller-owned dir's entries (it does not own that parent), and
        # every descent is O_NOFOLLOW, so widening the dir-owner gate to the
        # controller does not open a redirect: it only lets the walk reach
        # the iso-owned content under a controller-owned container.
        self.dir_owner_uids = set(
            u for u in (dir_owner_uids or ()) if u is not None
        )
        self.file_mode = file_mode
        self.dir_mode = dir_mode
        self.excl_names = set(excl_names or ())
        self.excl_basenames = set(excl_basenames or ())
        # #1766: a single TARGET-VALIDATED symlink whitelist. `accept_link_rel`
        # is the EXACT relpath within a walked root that may be a symlink
        # (e.g. `.claude/settings.json`); `accept_link_target` is the canonical
        # absolute path that link MUST realpath-resolve to (the agent's OWN
        # per-agent-root `settings.effective.json`). Only that one shape is
        # accepted; every OTHER symlink stays refused (the planted-redirect
        # guard for the rest of the tree is unchanged). The acceptance is
        # target-validated, NOT name-validated: a `.claude/settings.json` that
        # resolves anywhere else is still refused.
        self.accept_link_rel = accept_link_rel or None
        self.accept_link_target = (
            os.path.realpath(accept_link_target)
            if accept_link_target
            else None
        )
        self.published = 0
        self.ok = 0
        self.refused = 0
        self.failed = 0
        self.entries = 0

    def _dir_owner_ok(self, st):
        # A directory's owner is acceptable if it is the iso UID OR a
        # controller container owner (see dir_owner_uids note). An empty
        # gate set (no owners resolvable) accepts any owner — degrade open,
        # mirroring the file-owner gate's "skip the check" fallback.
        if not self.dir_owner_uids:
            return True
        return st.st_uid in self.dir_owner_uids

    def _mutate_meta(self, fd, st, target_mode, relpath, is_dir):
        # Idempotent short-circuit: already at contract → no syscall.
        if st.st_gid == self.gid and stat.S_IMODE(st.st_mode) == target_mode:
            self.ok += 1
            return
        try:
            os.fchown(fd, -1, self.gid)
        except OSError as exc:
            self.failed += 1
            _emit("mutate-failed", relpath, f"fchown:{exc.errno}")
            return
        try:
            os.fchmod(fd, target_mode)
        except OSError as exc:
            self.failed += 1
            _emit("mutate-failed", relpath, f"fchmod:{exc.errno}")
            return
        self.published += 1

    def _normalize_dir_meta(self, dir_fd, st, relpath):
        self._mutate_meta(dir_fd, st, self.dir_mode, relpath, is_dir=True)

    def _normalize_file(self, parent_fd, name, relpath):
        try:
            fd = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=parent_fd,
            )
        except FileNotFoundError:
            # Raced away between readdir and open — fine, skip.
            return
        except OSError as exc:
            if exc.errno in _SYMLINK_ERRNOS:
                self.refused += 1
                _emit("refused-symlink", relpath, "")
                return
            self.failed += 1
            _emit("mutate-failed", relpath, f"open:{exc.errno}")
            return
        try:
            st = os.fstat(fd)
            if stat.S_ISLNK(st.st_mode):
                # O_NOFOLLOW should have refused this, but double-check.
                self.refused += 1
                _emit("refused-symlink", relpath, "")
                return
            if not stat.S_ISREG(st.st_mode):
                self.refused += 1
                _emit(
                    "refused-nonregular", relpath, oct(stat.S_IFMT(st.st_mode))
                )
                return
            if self.want_uid is not None and st.st_uid != self.want_uid:
                self.refused += 1
                _emit("refused-owner", relpath, str(st.st_uid))
                return
            target = _target_file_mode(st.st_mode, self.file_mode)
            self._mutate_meta(fd, st, target, relpath, is_dir=False)
        finally:
            os.close(fd)

    def _maybe_accept_settings_link(self, dir_fd, name, child_rel):
        """#1766: accept the ONE canonical `settings.json` symlink whose
        target realpath-resolves to the agent's own per-agent-root effective
        render (the `accept_link_target`), and chgrp the LINK itself to the
        agent group via lchown (relative to the verified dir_fd — no path
        re-resolution race). Returns True if accepted (caller skips the
        refusal), False otherwise (caller refuses as before).

        Target-validated, not name-validated: the link's realpath MUST equal
        the pre-resolved `accept_link_target`; a `.claude/settings.json` that
        points anywhere else stays refused. lchown only ever touches the link
        inode (never follows), and only the GROUP is changed (never owner,
        never mode), so even if the iso UID swaps the link between the
        realpath check and the lchown the blast radius is at most grouping an
        attacker-owned link to the agent's OWN group — harmless."""
        if not self.accept_link_rel or not self.accept_link_target:
            return False
        if child_rel != self.accept_link_rel:
            return False
        try:
            target = os.readlink(name, dir_fd=dir_fd)
        except OSError:
            return False
        # Resolve the link target relative to the directory that CONTAINS the
        # link (dir_fd), using that directory's controller-resolved absolute
        # path threaded down the walk. A relative target (the canonical
        # `../../.claude/settings.effective.json`) and an absolute target are
        # both handled by os.path.join + realpath.
        link_dir_abs = self._current_dir_abs
        if not link_dir_abs:
            return False
        resolved = os.path.realpath(os.path.join(link_dir_abs, target))
        if resolved != self.accept_link_target:
            return False
        try:
            os.chown(name, -1, self.gid, dir_fd=dir_fd, follow_symlinks=False)
        except OSError as exc:
            self.failed += 1
            _emit("mutate-failed", child_rel, f"lchown:{exc.errno}")
            return True  # handled (do not also emit refused-symlink)
        self.published += 1
        _emit("accepted-settings-symlink", child_rel, resolved)
        return True

    def walk(self, root_fd, root_label, root_abspath=""):
        # Iterative DFS over an explicit
        # (dir_fd, relpath, depth, owns_fd, dir_abspath) stack so we never
        # re-resolve a path and never hand os.walk an fd it would follow. The
        # caller owns root_fd; we close every fd WE open. `dir_abspath` is the
        # controller-resolved absolute path of the directory `dir_fd` points
        # at — threaded ONLY so the #1766 settings-symlink acceptance can
        # realpath-validate the link target; it is never re-opened or mutated.
        self._current_dir_abs = ""
        stack = [(root_fd, root_label, 0, False, root_abspath)]
        while stack:
            dir_fd, relpath, depth, owns_fd, dir_abspath = stack.pop()
            self._current_dir_abs = dir_abspath
            try:
                if self.entries >= MAX_ENTRIES:
                    _emit("mutate-failed", relpath, "max-entries-exceeded")
                    self.failed += 1
                    continue
                self.entries += 1
                if depth > MAX_DEPTH:
                    _emit("mutate-failed", relpath, "max-depth-exceeded")
                    self.failed += 1
                    continue
                try:
                    st = os.fstat(dir_fd)
                except OSError as exc:
                    self.failed += 1
                    _emit("mutate-failed", relpath, f"fstat:{exc.errno}")
                    continue
                if not self._dir_owner_ok(st):
                    # A directory owned by neither the iso UID nor a
                    # controller container owner is anomalous; refuse it AND
                    # do not descend.
                    self.refused += 1
                    _emit("refused-owner", relpath, str(st.st_uid))
                    continue
                # Normalize this directory's own group + setgid mode first.
                self._normalize_dir_meta(dir_fd, st, relpath)
                # Read children. Prune the CONTENTS of an excluded top-level
                # subdir (depth==0 children) while leaving the subdir node
                # already normalized above.
                try:
                    names = os.listdir(dir_fd)
                except OSError as exc:
                    self.failed += 1
                    _emit("mutate-failed", relpath, f"listdir:{exc.errno}")
                    continue
                for name in names:
                    if name in (".", ".."):
                        continue
                    child_rel = f"{relpath}/{name}" if relpath else name
                    # Excluded top-level basename (HEARTBEAT.md / CHANGE-
                    # POLICY.md): skip ENTIRELY — neither chgrp/chmod nor
                    # descend. Only at the top level so a same-named entry
                    # deeper in the tree is still normalized.
                    if depth == 0 and name in self.excl_basenames:
                        continue
                    # Excluded top-level subdir: normalize the node itself
                    # (so the dir is group-traversable) but DO NOT descend
                    # into it — its files stay iso-UID 0600.
                    pruned = depth == 0 and name in self.excl_names
                    # Probe the child without following symlinks: lstat-style
                    # via O_NOFOLLOW open is overkill for the type check, so
                    # use a fstatat with AT_SYMLINK_NOFOLLOW to decide
                    # dir-vs-file-vs-link cheaply, then open the right way.
                    try:
                        cst = os.stat(
                            name,
                            dir_fd=dir_fd,
                            follow_symlinks=False,
                        )
                    except OSError as exc:
                        if exc.errno in _SYMLINK_ERRNOS:
                            self.refused += 1
                            _emit("refused-symlink", child_rel, "")
                        else:
                            self.failed += 1
                            _emit(
                                "mutate-failed", child_rel, f"statat:{exc.errno}"
                            )
                        continue
                    if stat.S_ISLNK(cst.st_mode):
                        # #1766: accept the ONE canonical self-target
                        # `settings.json -> settings.effective.json` link;
                        # every other symlink stays refused.
                        if self._maybe_accept_settings_link(
                            dir_fd, name, child_rel
                        ):
                            continue
                        self.refused += 1
                        _emit("refused-symlink", child_rel, "")
                        continue
                    if stat.S_ISDIR(cst.st_mode):
                        try:
                            cfd = os.open(
                                name,
                                os.O_RDONLY
                                | os.O_DIRECTORY
                                | os.O_NOFOLLOW
                                | os.O_NONBLOCK,
                                dir_fd=dir_fd,
                            )
                        except OSError as exc:
                            if exc.errno in _SYMLINK_ERRNOS:
                                self.refused += 1
                                _emit("refused-symlink", child_rel, "")
                            else:
                                self.failed += 1
                                _emit(
                                    "mutate-failed",
                                    child_rel,
                                    f"opendir:{exc.errno}",
                                )
                            continue
                        if pruned:
                            # Normalize the excluded subdir node, then close
                            # without descending.
                            try:
                                dst = os.fstat(cfd)
                                if self._dir_owner_ok(dst):
                                    self._normalize_dir_meta(
                                        cfd, dst, child_rel
                                    )
                                else:
                                    self.refused += 1
                                    _emit(
                                        "refused-owner",
                                        child_rel,
                                        str(dst.st_uid),
                                    )
                            finally:
                                os.close(cfd)
                            continue
                        child_abspath = (
                            os.path.join(dir_abspath, name)
                            if dir_abspath
                            else ""
                        )
                        stack.append(
                            (cfd, child_rel, depth + 1, True, child_abspath)
                        )
                    elif stat.S_ISREG(cst.st_mode):
                        self._normalize_file(dir_fd, name, child_rel)
                    else:
                        self.refused += 1
                        _emit(
                            "refused-nonregular",
                            child_rel,
                            oct(stat.S_IFMT(cst.st_mode)),
                        )
            finally:
                if owns_fd:
                    try:
                        os.close(dir_fd)
                    except OSError:
                        pass


def _open_root(root):
    return os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("group")
    ap.add_argument("file_mode")  # octal, e.g. 0660
    ap.add_argument("dir_mode")   # octal, e.g. 2770
    ap.add_argument("iso_user")   # expected owner; "" skips the owner gate
    ap.add_argument("roots", nargs="+")
    ap.add_argument("--exclude-subdir", action="append", default=[])
    ap.add_argument("--exclude-name", action="append", default=[])
    # The controller user that OWNS the prepared container dirs
    # (`home`/`workdir`/`runtime`/`logs` at `controller:2770`). Accepted as
    # a valid DIRECTORY owner in addition to the iso UID so the walk can
    # descend through those controller-owned containers to reach the
    # iso-owned content beneath. Regular FILES are still gated strictly to
    # the iso UID. Empty / unresolvable → dir-owner gate is skipped.
    ap.add_argument("--controller-user", default="")
    # #1766: target-validated symlink acceptance for the canonical
    # `settings.json -> settings.effective.json` link. `--accept-settings-link-rel`
    # is the EXACT relpath (within a walked root) that may be a symlink (the
    # workdir-relative `.claude/settings.json`); `--accept-settings-link-target`
    # is the canonical absolute path it MUST realpath-resolve to (the agent's
    # own per-agent-root settings.effective.json). Both must be supplied to
    # enable the acceptance; otherwise EVERY symlink stays refused (unchanged).
    ap.add_argument("--accept-settings-link-rel", default="")
    ap.add_argument("--accept-settings-link-target", default="")
    args = ap.parse_args(argv[1:])

    try:
        file_mode = int(args.file_mode, 8)
        dir_mode = int(args.dir_mode, 8)
    except ValueError:
        sys.stderr.write("fatal: bad octal mode\n")
        return 2

    try:
        gid = grp.getgrnam(args.group).gr_gid
    except KeyError:
        sys.stderr.write(f"fatal: group not found: {args.group}\n")
        return 2

    import pwd

    want_uid = None
    if args.iso_user:
        try:
            want_uid = pwd.getpwnam(args.iso_user).pw_uid
        except KeyError:
            want_uid = None

    controller_uid = None
    if args.controller_user:
        try:
            controller_uid = pwd.getpwnam(args.controller_user).pw_uid
        except KeyError:
            controller_uid = None

    # Directory owner gate: iso UID + controller container owner (both
    # legitimate). Only meaningful when the iso UID is known; if it is not,
    # leave the gate empty (accept any) so we degrade open rather than
    # refuse every directory.
    dir_owner_uids = ()
    if want_uid is not None:
        dir_owner_uids = tuple(
            u for u in (want_uid, controller_uid) if u is not None
        )

    walker = Walker(
        gid,
        want_uid,
        dir_owner_uids,
        file_mode,
        dir_mode,
        args.exclude_subdir,
        args.exclude_name,
        accept_link_rel=(args.accept_settings_link_rel or None),
        accept_link_target=(args.accept_settings_link_target or None),
    )

    opened_any = False
    for root in args.roots:
        try:
            root_fd = _open_root(root)
        except FileNotFoundError:
            # A missing root is fine (partial tree) — skip it.
            continue
        except OSError as exc:
            if exc.errno in _SYMLINK_ERRNOS:
                _emit("refused-symlink", root, "root")
                continue
            sys.stderr.write(f"fatal: cannot open root {root!r}: {exc.errno}\n")
            return 2
        opened_any = True
        try:
            # Pass the root's controller-resolved absolute path so the #1766
            # settings-symlink acceptance can realpath-validate the link
            # target. realpath of the root only (a controller-owned container
            # whose parent is controller-owned) — never re-resolves content.
            walker.walk(root_fd, "", os.path.realpath(root))
        finally:
            os.close(root_fd)

    if not opened_any:
        # No root was openable AND none were missing-but-fine — this is the
        # all-absent case, which is a benign no-op (return 0, empty summary).
        pass

    _emit(
        "summary",
        ",".join(args.roots),
        f"published={walker.published},ok={walker.ok},"
        f"refused={walker.refused},failed={walker.failed},"
        f"entries={walker.entries}",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
