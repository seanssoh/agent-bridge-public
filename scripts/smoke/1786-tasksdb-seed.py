#!/usr/bin/env python3
"""File-as-argv tasks.db fixture seeder for scripts/smoke/1786-tasksdb-doctor-verb.sh.

Exists so the smoke can build sqlite fixtures without any heredoc-stdin
`python3 -` subprocess (footgun #11 / lint-heredoc-ban). Every mode takes the
target db path as an explicit argv argument.

Usage:
  1786-tasksdb-seed.py <mode> <db-path>

Modes:
  plain        A minimal rollback-journaled (non-WAL) db with one table.
  wal-healthy  A healthy WAL-journaled db with the -wal/-shm sidecars
               REMOVED — the exact #1786 case where a `mode=ro` read fails
               SQLITE_CANTOPEN but the db is perfectly readable via
               `immutable=1`.
  corrupt      A db that opens but fails `PRAGMA quick_check` (a mid-file page
               is zeroed out).
  not-a-db     A file whose bytes are NOT a sqlite database at all (damaged /
               replaced header). The probe read raises a non-Operational
               `DatabaseError` ("file is not a database") — must classify
               `corrupt`, never `unverifiable` (#1786 codex r3).
  wal-unmerged A WAL-journaled db left with a NON-EMPTY `-wal` (committed but
               un-checkpointed pages) and NO `-shm` — the case where a
               `mode=ro` read CANTOPENs and an `immutable=1` fallback would
               silently bypass the WAL pages (#1786 codex r1). Must classify
               `unverifiable`, never a stale `ok`.

Read-only side effects beyond creating the named db: removes the db's own
-wal/-shm sidecars in `wal-healthy` mode; in `wal-unmerged` mode removes only
the `-shm` and leaves a non-empty `-wal`.
"""

from __future__ import annotations

import os
import sqlite3
import sys
from pathlib import Path


def _seed_plain(db: Path) -> None:
    conn = sqlite3.connect(str(db))
    try:
        conn.execute("CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT)")
        conn.execute("INSERT INTO tasks(title) VALUES ('t')")
        conn.commit()
    finally:
        conn.close()


def _seed_wal_healthy(db: Path) -> None:
    conn = sqlite3.connect(str(db))
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT)")
        conn.execute("INSERT INTO tasks(title) VALUES ('t')")
        conn.commit()
    finally:
        conn.close()
    # Drop the sidecars so a fresh `mode=ro` read from a separate process must
    # (and cannot) recreate the -shm — the #1786 false-negative trigger.
    for suffix in ("-wal", "-shm"):
        sidecar = Path(str(db) + suffix)
        if sidecar.exists():
            sidecar.unlink()


def _seed_wal_unmerged(db: Path) -> None:
    # A genuine WAL-journaled db left with committed-but-uncheckpointed pages
    # in `-wal` (autocheckpoint off so close does not merge them) and NO
    # `-shm`. The `-wal` is a REAL sqlite WAL (snapshotted live before close),
    # so a `mode=ro` open that has to recreate `-shm` will CANTOPEN when the
    # dir is read-only — the exact "immutable read would skip WAL pages"
    # condition (#1786 codex r1). The smoke makes the dir read-only.
    conn = sqlite3.connect(str(db))
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA wal_autocheckpoint=0")
        conn.execute("CREATE TABLE tasks(id INTEGER PRIMARY KEY, v TEXT)")
        conn.execute("INSERT INTO tasks(v) VALUES ('committed-in-wal')")
        conn.commit()
        # Snapshot the live (non-empty) -wal before close auto-merges it.
        live_wal = Path(str(db) + "-wal")
        snapshot = live_wal.read_bytes()
    finally:
        conn.close()
    # Restore the non-empty -wal; drop the -shm so a fresh mode=ro must
    # recreate it (and CANTOPENs under a read-only dir).
    Path(str(db) + "-wal").write_bytes(snapshot)
    shm = Path(str(db) + "-shm")
    if shm.exists():
        shm.unlink()


def _seed_not_a_db(db: Path) -> None:
    # Bytes that are NOT a valid sqlite header — sqlite raises
    # `DatabaseError: file is not a database` on the first read.
    db.write_bytes(b"this is not a sqlite database, just plain text\n" * 64)


def _seed_corrupt(db: Path) -> None:
    conn = sqlite3.connect(str(db))
    try:
        conn.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB)")
        for _ in range(200):
            conn.execute("INSERT INTO t(v) VALUES (?)", (b"x" * 400,))
        conn.commit()
    finally:
        conn.close()
    size = os.path.getsize(db)
    with open(db, "r+b") as fh:
        fh.seek(size // 2)
        fh.write(b"\x00" * 200)


def _probe_mode_ro(db: Path) -> int:
    """Read-only precondition probe for the smoke's F2 phase. Opens *db* with
    `mode=ro` + a probe read and prints `cantopen` (SQLITE_CANTOPEN — the
    forced-fallback condition) or `ok` (mode=ro read succeeded). Never seeds
    or mutates the db. Prints `other:<err>` for any unexpected error so the
    caller can skip rather than mis-assert.
    """
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        conn.execute("PRAGMA schema_version").fetchone()
        conn.close()
        print("ok")
    except sqlite3.OperationalError as exc:
        print("cantopen" if "unable to open" in str(exc).lower() else f"other:{exc}")
    except sqlite3.Error as exc:
        print(f"other:{exc}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        raise SystemExit(
            "usage: 1786-tasksdb-seed.py "
            "<plain|wal-healthy|wal-unmerged|corrupt|not-a-db|probe-mode-ro> <db-path>"
        )
    mode, db_path = argv[1], Path(argv[2])
    if mode == "probe-mode-ro":
        # Read-only probe of an EXISTING fixture — no mkdir / unlink / seeding.
        return _probe_mode_ro(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if db_path.exists():
        db_path.unlink()
    if mode == "plain":
        _seed_plain(db_path)
    elif mode == "wal-healthy":
        _seed_wal_healthy(db_path)
    elif mode == "wal-unmerged":
        _seed_wal_unmerged(db_path)
    elif mode == "corrupt":
        _seed_corrupt(db_path)
    elif mode == "not-a-db":
        _seed_not_a_db(db_path)
    else:
        raise SystemExit(f"unknown mode: {mode}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
