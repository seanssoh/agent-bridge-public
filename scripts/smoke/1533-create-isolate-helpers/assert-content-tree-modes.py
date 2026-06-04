#!/usr/bin/env python3
"""#1533 — recursive metadata assertion for
``bridge_isolation_v2_publish_content_tree`` /
``isolation-normalize-content-tree.py``.

A dir-level assertion FALSE-PASSES the create-time content-normalize gap
(the bug: the top dir was correct at 2770 while every FILE underneath
stayed 0600). This helper walks the tree and asserts EACH regular file is
at the published file-mode (group-readable) and EACH directory is at the
published dir-mode (setgid), while asserting the negative controls were
NOT relaxed.

Usage:
  assert-content-tree-modes.py <root> \
      --published-file-mode 0660 \
      --published-dir-mode 2770 \
      [--exec-file <rel>[,<rel>...]] \
      [--owner-only <rel>[,<rel>...]] \
      [--excluded-subdir-content <rel>[,<rel>...]] \
      [--symlink <rel>[,<rel>...]] \
      [--min-files N]

  <root>                       tree root (e.g. .../home)
  --published-file-mode <oct>  expected mode for every NON-exec regular
                               file not in an exclusion (e.g. 0660); the
                               group-read bit MUST be set
  --published-dir-mode <oct>   expected mode for every directory not in an
                               excluded subtree (e.g. 2770); setgid + group
                               bits MUST be set
  --exec-file <csv>            root-relative regular files that carry an
                               exec bit and MUST be group-exec (e.g. 0770) —
                               proves the walker preserved +x
  --owner-only <csv>           root-relative paths that MUST stay 0600
                               (group-read CLEAR) — HEARTBEAT.md etc.
  --excluded-subdir-content <csv>
                               root-relative FILES inside an excluded
                               subdir (e.g. .teams/.env) that MUST stay
                               0600 (group-read CLEAR)
  --symlink <csv>              root-relative paths that MUST remain symlinks
  --min-files N                FAIL if fewer than N published files were
                               found (guards against a tree that the walker
                               never reached — a false-pass on an empty set)

Reports every mismatch for debuggability; exit 0 only when all hold.
"""
import argparse
import os
import stat
import sys


def _csv(val):
    return [x.strip() for x in (val or "").split(",") if x.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--published-file-mode", required=True)
    ap.add_argument("--published-dir-mode", required=True)
    ap.add_argument("--exec-file", default="")
    ap.add_argument("--owner-only", default="")
    ap.add_argument("--excluded-subdir-content", default="")
    ap.add_argument("--symlink", default="")
    ap.add_argument("--min-files", type=int, default=0)
    args = ap.parse_args()

    root = args.root
    pub_file = int(args.published_file_mode, 8)
    pub_dir = int(args.published_dir_mode, 8)
    exec_files = set(_csv(args.exec_file))
    owner_only = set(_csv(args.owner_only))
    excluded_content = set(_csv(args.excluded_subdir_content))
    symlinks = set(_csv(args.symlink))

    if not os.path.isdir(root):
        print(f"FAIL: root does not exist: {root}")
        return 1

    failures = []
    published_count = 0

    # The set of relpaths whose 0600/symlink contract is checked separately.
    special = owner_only | excluded_content | symlinks

    for dirpath, dirnames, filenames in os.walk(root):
        # Do not descend INTO an excluded subdir's children via this assert
        # (their content is checked via --excluded-subdir-content), but we
        # still must reach those files to stat them, so keep walking — the
        # special-case below handles their expected 0600.
        for d in dirnames:
            abs_d = os.path.join(dirpath, d)
            rel = os.path.relpath(abs_d, root)
            if os.path.islink(abs_d):
                # A symlinked dir is only acceptable if explicitly declared.
                if rel not in symlinks:
                    failures.append(f"{rel}: unexpected symlinked directory")
                continue
            m = os.stat(abs_d).st_mode & 0o7777
            # A directory inside an excluded subtree may keep its own mode;
            # we only assert dirs NOT under an excluded relpath. Detect that
            # by checking whether any excluded-content prefix matches.
            in_excluded = any(
                rel == ec or rel.startswith(ec + os.sep)
                for ec in excluded_content
            ) or rel in special
            if in_excluded:
                continue
            if m != pub_dir:
                failures.append(
                    f"{rel}/: dir mode {oct(m)} != expected {oct(pub_dir)}"
                )
        for f in filenames:
            abs_f = os.path.join(dirpath, f)
            rel = os.path.relpath(abs_f, root)
            if os.path.islink(abs_f):
                if rel not in symlinks:
                    failures.append(f"{rel}: unexpected symlink")
                continue
            m = os.stat(abs_f).st_mode & 0o7777
            if rel in owner_only or rel in excluded_content:
                if m & stat.S_IRGRP:
                    failures.append(
                        f"{rel}: group-read SET (mode {oct(m)}) — must stay "
                        f"owner-only 0600 (excluded)"
                    )
                continue
            if rel in exec_files:
                # Exec file: must be group-readable AND group-exec.
                if not (m & stat.S_IRGRP):
                    failures.append(f"{rel}: exec file group-read CLEAR "
                                    f"(mode {oct(m)})")
                if not (m & stat.S_IXGRP):
                    failures.append(f"{rel}: exec file group-exec CLEAR "
                                    f"(mode {oct(m)}) — +x not preserved")
                published_count += 1
                continue
            # Ordinary published file.
            if m != pub_file:
                failures.append(
                    f"{rel}: mode {oct(m)} != expected {oct(pub_file)}"
                )
            if not (m & stat.S_IRGRP):
                failures.append(f"{rel}: group-read bit CLEAR (mode {oct(m)})")
            published_count += 1

    # Symlinks declared must still be symlinks.
    for rel in symlinks:
        p = os.path.join(root, rel)
        if os.path.lexists(p) and not os.path.islink(p):
            failures.append(f"{rel}: no longer a symlink (publish followed it)")

    if published_count < args.min_files:
        failures.append(
            f"only {published_count} published files found "
            f"(< --min-files {args.min_files}) — walker may not have reached "
            f"the tree (false-pass guard)"
        )

    if failures:
        print("FAIL:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print(
        f"PASS — {published_count} published file(s) @ "
        f"{oct(pub_file)}/{oct(pub_dir)}, "
        f"{len(owner_only)} owner-only + {len(excluded_content)} excluded "
        f"preserved, {len(symlinks)} symlink(s) preserved"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
