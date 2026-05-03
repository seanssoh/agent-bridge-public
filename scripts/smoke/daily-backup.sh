#!/usr/bin/env bash
#
# scripts/smoke/daily-backup.sh — issue #507 regression coverage.
#
# Exercises the daily-backup pipeline end-to-end against an isolated tmp
# BRIDGE_HOME without touching any live install:
#   1. Snapshot content      — today's SQL dump present, raw tasks.db absent
#   2. Stale tmp reaping     — old *.tgz.tmp.* deleted, fresh ones preserved
#   3. Disk-full skip        — outcome=skipped_disk_full, no archive created
#   4. Missing tasks.db      — fresh install still produces a valid archive
#   5. Cleanup-residue path  — cleanup_failures empty on the happy path
#
# Lock-concurrency coverage is omitted from this script — it would require
# spawning two long-lived python processes and racing on a shared lock,
# which is fragile under CI. Lock acquire/release is unit-testable via
# acquire_daily_backup_lock; keep that for follow-up if needed.

set -euo pipefail

SMOKE_NAME="daily-backup"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd tar
smoke_require_cmd sqlite3

PYTHON_PARSE_OUTCOME="$(cat <<'PY'
import json, sys
data = json.loads(sys.stdin.read())
print(data.get("outcome", ""))
PY
)"

PYTHON_LIST_TAR_MEMBERS="$(cat <<'PY'
import sys, tarfile

archive = sys.argv[1]
with tarfile.open(archive, "r:gz") as tf:
    for member in tf.getmembers():
        print(member.name)
PY
)"

PYTHON_SEED_TASKS_DB="$(cat <<'PY'
import sqlite3, sys
db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
conn.execute("CREATE TABLE IF NOT EXISTS smoke_marker (k TEXT PRIMARY KEY, v TEXT)")
conn.executemany("INSERT OR REPLACE INTO smoke_marker VALUES (?,?)",
                 [("seeded", "yes"), ("issue", "507")])
conn.commit()
conn.close()
PY
)"

setup_bridge_home() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  mkdir -p "$BRIDGE_HOME/state" "$BRIDGE_HOME/backups/daily" \
    "$BRIDGE_HOME/state/backup-snapshots"
  printf 'live state\n' >"$BRIDGE_HOME/state/probe.txt"
}

step_snapshot_content() {
  setup_bridge_home

  python3 - "$BRIDGE_HOME/state/tasks.db" <<<"$PYTHON_SEED_TASKS_DB"

  local payload outcome
  payload="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" daily-backup-live \
    --target-root "$BRIDGE_HOME" \
    --backup-dir "$BRIDGE_HOME/backups/daily" \
    --retain-days 7)"
  outcome="$(printf '%s' "$payload" | python3 -c "$PYTHON_PARSE_OUTCOME")"
  [[ "$outcome" == "created" ]] || smoke_fail "snapshot_content: outcome=$outcome (want created)"

  local archive
  archive="$(printf '%s' "$payload" \
    | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("archive_path",""))')"
  [[ -f "$archive" ]] || smoke_fail "snapshot_content: archive missing at $archive"

  local members
  members="$(python3 -c "$PYTHON_LIST_TAR_MEMBERS" "$archive")"
  printf '%s\n' "$members" | grep -q '^state/backup-snapshots/tasks-.*\.sql\.gz$' \
    || smoke_fail "snapshot_content: today's SQL dump missing from archive"
  if printf '%s\n' "$members" | grep -qE '^state/tasks\.db(-wal|-shm|-journal)?$'; then
    smoke_fail "snapshot_content: raw tasks.db leaked into archive"
  fi
  # Sanity: the snapshot file restores cleanly into a temp DB.
  local snapshot_in_tar restored_db
  snapshot_in_tar="$(printf '%s\n' "$members" | grep '^state/backup-snapshots/tasks-.*\.sql\.gz$' | head -1)"
  restored_db="$(mktemp "$SMOKE_TMP_ROOT/restored.XXXXXX.sqlite")"
  tar -xOzf "$archive" "$snapshot_in_tar" | gunzip | sqlite3 "$restored_db" \
    || smoke_fail "snapshot_content: SQL dump did not round-trip"
  sqlite3 "$restored_db" "SELECT v FROM smoke_marker WHERE k='seeded'" \
    | grep -qx 'yes' \
    || smoke_fail "snapshot_content: restored DB missing seed row"

  smoke_log "snapshot_content OK (archive=$archive)"
}

step_stale_tmp_reap() {
  setup_bridge_home
  python3 - "$BRIDGE_HOME/state/tasks.db" <<<"$PYTHON_SEED_TASKS_DB"

  local backup_dir="$BRIDGE_HOME/backups/daily"
  local stale="$backup_dir/agent-bridge-2025-01-01.tgz.tmp.99999"
  local fresh="$backup_dir/agent-bridge-2025-01-02.tgz.tmp.88888"

  : >"$stale"
  : >"$fresh"
  # Force the stale tmp's mtime well outside the grace window. Default
  # grace is 180s; use 24h to leave no doubt.
  touch -t "$(date -u -v-1d +%Y%m%d%H%M 2>/dev/null \
              || date -u -d '1 day ago' +%Y%m%d%H%M)" "$stale"

  python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" daily-backup-live \
    --target-root "$BRIDGE_HOME" \
    --backup-dir "$backup_dir" \
    --retain-days 7 >/dev/null

  if [[ -e "$stale" ]]; then
    smoke_fail "stale_tmp_reap: stale tmp not removed: $stale"
  fi
  if [[ ! -e "$fresh" ]]; then
    smoke_fail "stale_tmp_reap: fresh tmp wrongly removed (would steal a peer's in-flight write)"
  fi
  rm -f "$fresh"

  smoke_log "stale_tmp_reap OK"
}

step_disk_full_skip() {
  setup_bridge_home
  python3 - "$BRIDGE_HOME/state/tasks.db" <<<"$PYTHON_SEED_TASKS_DB"

  local payload outcome
  payload="$(BRIDGE_DAILY_BACKUP_FREE_BYTES_OVERRIDE=0 \
    python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" daily-backup-live \
      --target-root "$BRIDGE_HOME" \
      --backup-dir "$BRIDGE_HOME/backups/daily" \
      --retain-days 7)"
  outcome="$(printf '%s' "$payload" | python3 -c "$PYTHON_PARSE_OUTCOME")"
  [[ "$outcome" == "skipped_disk_full" ]] \
    || smoke_fail "disk_full_skip: outcome=$outcome (want skipped_disk_full)"
  if compgen -G "$BRIDGE_HOME/backups/daily/agent-bridge-*.tgz" >/dev/null; then
    smoke_fail "disk_full_skip: archive was created despite disk-full"
  fi

  smoke_log "disk_full_skip OK"
}

step_missing_tasks_db() {
  setup_bridge_home
  # Intentionally do NOT seed state/tasks.db — fresh install case.
  rm -f "$BRIDGE_HOME/state/tasks.db"

  local payload outcome
  payload="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" daily-backup-live \
    --target-root "$BRIDGE_HOME" \
    --backup-dir "$BRIDGE_HOME/backups/daily" \
    --retain-days 7)"
  outcome="$(printf '%s' "$payload" | python3 -c "$PYTHON_PARSE_OUTCOME")"
  [[ "$outcome" == "created" ]] \
    || smoke_fail "missing_tasks_db: outcome=$outcome (fresh install must still create archive)"

  local archive
  archive="$(printf '%s' "$payload" \
    | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("archive_path",""))')"
  if python3 -c "$PYTHON_LIST_TAR_MEMBERS" "$archive" \
       | grep -qE '^state/tasks\.db(-wal|-shm|-journal)?$'; then
    smoke_fail "missing_tasks_db: raw tasks.db unexpectedly present"
  fi

  smoke_log "missing_tasks_db OK"
}

step_corrupted_tasks_db_blocks_archive() {
  setup_bridge_home
  # Plant a non-sqlite blob at state/tasks.db. dump_sqlite_snapshot will
  # call .backup() against it, which fails with "file is not a database".
  # The PR #508 r3 guard must convert that into outcome=error_sqlite_snapshot
  # rather than letting the daemon mark `created` and prune older good
  # backups. (Codex r2 blocker reproduction.)
  printf 'this is not a sqlite database\n' >"$BRIDGE_HOME/state/tasks.db"

  local payload outcome
  payload="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" daily-backup-live \
    --target-root "$BRIDGE_HOME" \
    --backup-dir "$BRIDGE_HOME/backups/daily" \
    --retain-days 7)"
  outcome="$(printf '%s' "$payload" | python3 -c "$PYTHON_PARSE_OUTCOME")"
  [[ "$outcome" == "error_sqlite_snapshot" ]] \
    || smoke_fail "corrupted_tasks_db: outcome=$outcome (want error_sqlite_snapshot)"

  if compgen -G "$BRIDGE_HOME/backups/daily/agent-bridge-*.tgz" >/dev/null; then
    smoke_fail "corrupted_tasks_db: archive was created despite snapshot failure"
  fi

  smoke_log "corrupted_tasks_db_blocks_archive OK"
}

step_cleanup_residue_happy_path() {
  setup_bridge_home

  # Seed a stale tmp + an old daily archive so cleanup has something to do.
  local backup_dir="$BRIDGE_HOME/backups/daily"
  : >"$backup_dir/agent-bridge-2024-01-01.tgz.tmp.55555"
  touch -t "$(date -u -v-1d +%Y%m%d%H%M 2>/dev/null \
              || date -u -d '1 day ago' +%Y%m%d%H%M)" \
    "$backup_dir/agent-bridge-2024-01-01.tgz.tmp.55555"

  local payload failures
  payload="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" cleanup-residue \
    --target-root "$BRIDGE_HOME" \
    --backup-dir "$backup_dir" \
    --upgrade-backups-dir "$BRIDGE_HOME/backups" \
    --claude-config-path "$SMOKE_TMP_ROOT/.claude.json")"
  # Provide a valid stub config so the validate step doesn't false-fail.
  printf '{}\n' >"$SMOKE_TMP_ROOT/.claude.json"
  payload="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" cleanup-residue \
    --target-root "$BRIDGE_HOME" \
    --backup-dir "$backup_dir" \
    --upgrade-backups-dir "$BRIDGE_HOME/backups" \
    --claude-config-path "$SMOKE_TMP_ROOT/.claude.json")"

  failures="$(printf '%s' "$payload" \
    | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read()).get("cleanup_failures") or []))')"
  [[ "$failures" == "0" ]] \
    || smoke_fail "cleanup_residue: cleanup_failures=$failures (want 0)"

  if compgen -G "$backup_dir/*.tgz.tmp.*" >/dev/null; then
    smoke_fail "cleanup_residue: stale tmp survived"
  fi

  smoke_log "cleanup_residue_happy_path OK"
}

main() {
  smoke_log "starting issue #507 regression smoke"
  step_snapshot_content
  step_stale_tmp_reap
  step_disk_full_skip
  step_missing_tasks_db
  step_corrupted_tasks_db_blocks_archive
  step_cleanup_residue_happy_path
  smoke_log "all daily-backup checks passed"
}

main "$@"
