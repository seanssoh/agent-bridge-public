#!/usr/bin/env python3
"""
lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py — standalone
helper for `agb plugins seed` (bridge-plugins.sh).

Merges (idempotently) a `<marketplace_name>: {source: {source: directory,
path: <root>}, installLocation: <root>, lastUpdated: <iso>}` entry into
an existing known_marketplaces.json file. If the entry is already
present with the right shape, the file is left untouched (no rewrite,
so the mtime stays stable). Otherwise the merged content is written
atomically via a same-dir temp + os.replace.

The output goes to <out_path>; if <out_path> exists and the entry is
already correct, the helper exits 0 and prints `already-correct`.
Otherwise it prints `updated` (or `created` if the source was missing).

File-as-argv per footgun #11. Mirrors `ensure_known_marketplace_for_root`
in bridge-dev-plugin-cache.py but writes to an arbitrary output path
(L1-D iso UID propagation: same payload shape, different destination
than the controller's $HOME/.claude/plugins/known_marketplaces.json).

Usage:
  python3 lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py \
    <in_path_or_-> <out_path> <marketplace_name> <root>
"""

from __future__ import annotations

import datetime
import fcntl
import json
import os
import sys
from pathlib import Path


def _now_iso_utc() -> str:
    return datetime.datetime.now(tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _matches(entry: object, root: str) -> bool:
    if not isinstance(entry, dict):
        return False
    if str(entry.get("installLocation") or "").strip() != root:
        return False
    source = entry.get("source")
    if not isinstance(source, dict):
        return False
    return (
        str(source.get("source") or "").strip() == "directory"
        and str(source.get("path") or "").strip() == root
    )


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        sys.stderr.write(
            "usage: plugins-seed-merge-known-marketplace.py "
            "<in_path_or_-> <out_path> <marketplace_name> <root>\n"
        )
        return 2
    in_path, out_path, marketplace_name, root = argv[1:]
    marketplace_name = marketplace_name.strip()
    root = root.strip()
    if not marketplace_name:
        sys.stderr.write("marketplace_name is empty\n")
        return 1
    if not root:
        sys.stderr.write("root is empty\n")
        return 1

    # L1-D Part C (beta22, codex r1 race-safety, 2026-05-25): take a
    # sidecar `known_marketplaces.json.lock` flock so this seed-side
    # writer serializes against the start-hook
    # `ensure_known_marketplace_for_root` writer in
    # bridge-dev-plugin-cache.py. Identical convention to the
    # installed_plugins.json.lock + LOCK_EX pattern in
    # bridge-dev-plugin-cache.py:merge_installed_plugins. Without this,
    # concurrent runs (`agb plugins seed` D2 propagation + start-time
    # share-catalog re-derivation + dev-plugin-cache sync) could land a
    # read-modify-write that loses one writer's entry.
    out_dir = os.path.dirname(out_path) or "."
    os.makedirs(out_dir, exist_ok=True)
    lock_path = os.path.join(out_dir, os.path.basename(out_path) + ".lock")
    try:
        lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as exc:
        sys.stderr.write(f"lock-open-failed: {exc}\n")
        return 1
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
        except OSError as exc:
            sys.stderr.write(f"flock-failed: {exc}\n")
            return 1

        payload: dict[str, object] = {}
        # in_path == "-" means "no source, start from {}"; otherwise read
        # existing known_marketplaces.json if present. Read happens UNDER
        # the lock so we observe any commit from a peer writer that
        # landed just before us.
        if in_path != "-" and os.path.exists(in_path):
            try:
                with open(in_path, "r", encoding="utf-8") as fh:
                    loaded = json.load(fh)
                if isinstance(loaded, dict):
                    payload = loaded
            except (OSError, ValueError) as exc:
                sys.stderr.write(f"warning: could not parse {in_path}: {exc} — starting from empty payload\n")
                payload = {}

        existing = payload.get(marketplace_name) if isinstance(payload, dict) else None
        if _matches(existing, root):
            # Touch nothing — already correct. But still ensure out_path
            # exists when it differs from in_path (D2 iso copy case).
            if os.path.abspath(in_path) != os.path.abspath(out_path) and not os.path.exists(out_path):
                # Write the same content out so the destination is present.
                pass
            else:
                print("already-correct")
                return 0

        payload[marketplace_name] = {
            "source": {"source": "directory", "path": root},
            "installLocation": root,
            "lastUpdated": _now_iso_utc(),
        }
        # Determine the mode to preserve. If out_path exists, keep its mode;
        # otherwise default to 0640 (group-readable, the iso UID is in the
        # ab-agent-<a> group as a supplementary group, so g+r is enough).
        mode = 0o640
        if os.path.exists(out_path):
            try:
                mode = os.stat(out_path).st_mode & 0o777
            except OSError:
                mode = 0o640
        tmp_path = Path(out_path).with_name(f"{Path(out_path).name}.tmp.{os.getpid()}")
        try:
            tmp_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            os.chmod(tmp_path, mode)
            os.replace(tmp_path, out_path)
        finally:
            try:
                if tmp_path.exists():
                    tmp_path.unlink()
            except OSError:
                pass
        print("updated" if existing is not None else "created")
        return 0
    finally:
        try:
            os.close(lock_fd)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
