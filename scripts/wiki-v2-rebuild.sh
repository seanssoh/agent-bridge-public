#!/usr/bin/env bash
# wiki-v2-rebuild — rebuild each active claude agent's hybrid v2 index
# sequentially with atomic swap. Each agent takes 30-60s on Mac mini; 22 agents
# ≈ 15 min. Never run parallel (RAM + disk contention).
#
# Cron: Saturday 06:00 KST ("cron 0 6 * * 6 Asia/Seoul").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

JOB="wiki-v2-rebuild"
LOG="$(audit_path "$JOB")"
log_audit "$JOB" "starting $JOB" >/dev/null

trap 'file_failure_task "$JOB" "$LOG"' ERR

ok=0
fail=0
skipped=0

while IFS=$'\t' read -r agent home; do
  [[ -z "$agent" || -z "$home" ]] && continue
  log_audit "$JOB" "== agent=$agent home=$home ==" >/dev/null

  # Live DB path matches bridge-memory default (home/memory/index.sqlite).
  live_db="$home/memory/index.sqlite"
  tmp_db="$live_db.rebuilding"
  lock_file="$live_db.lock"

  if ! mkdir -p "$(dirname "$live_db")" 2>/dev/null; then
    log_audit "$JOB" "MKDIR_FAIL skip agent=$agent path=$(dirname "$live_db")" >/dev/null
    skipped=$((skipped + 1))
    continue
  fi
  if ! : 2>/dev/null >> "$lock_file"; then
    log_audit "$JOB" "LOCK_INIT_FAIL skip agent=$agent path=$lock_file" >/dev/null
    skipped=$((skipped + 1))
    continue
  fi

  # Acquire an exclusive lock so a manual rebuild can't interleave.
  # shellcheck disable=SC2094
  (
    # 60s wait for the lock; abort if we can't get it.
    if ! run_with_timeout 60 "$BRIDGE_PYTHON" - "$lock_file" <<'PY'
import fcntl, sys, time
path = sys.argv[1]
with open(path, "a+") as f:
    # Try non-blocking first; if contended, block for up to 30s.
    start = time.time()
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.time() - start > 30:
                sys.exit(11)
            time.sleep(1)
    # Hold the lock briefly to assert exclusivity, then exit;
    # the caller continues with the db path under convention.
PY
    then
      echo "rebuild-index: lock busy on $lock_file" >> "$LOG"
      exit 11
    fi
  ) || {
    log_audit "$JOB" "LOCK_BUSY skip agent=$agent" >/dev/null
    skipped=$((skipped + 1))
    continue
  }

  # Clean any stale temp DB from a previous abort.
  rm -f "$tmp_db"

  if ! run_with_timeout 900 "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" rebuild-index \
        --agent "$agent" --home "$home" \
        --bridge-home "$BRIDGE_HOME" \
        --index-kind bridge-wiki-hybrid-v2 \
        --shared-root "$BRIDGE_SHARED_ROOT" \
        --db-path "$tmp_db" \
        --json \
        >>"$LOG" 2>&1; then
    rc=$?
    log_audit "$JOB" "FAIL($rc) rebuild agent=$agent — tmp_db kept for inspection" >/dev/null
    fail=$((fail + 1))
    # Don't rename a failed build; next run will retry.
    continue
  fi

  # Validate the temp DB before atomic swap.
  if ! "$BRIDGE_PYTHON" - "$tmp_db" <<'PY'
import sqlite3, sys
p = sys.argv[1]
try:
    con = sqlite3.connect(p)
    cur = con.cursor()
    cur.execute("SELECT value FROM meta WHERE key='index_kind'")
    row = cur.fetchone()
    kind = row[0] if row else ""
    cur.execute("SELECT COUNT(*) FROM chunks")
    chunks = cur.fetchone()[0]
    con.close()
except Exception as e:
    print(f"validate-err: {e}", file=sys.stderr)
    sys.exit(2)
if kind != "bridge-wiki-hybrid-v2":
    print(f"wrong-kind: {kind}", file=sys.stderr)
    sys.exit(3)
if chunks <= 0:
    print(f"empty-chunks: {chunks}", file=sys.stderr)
    sys.exit(4)
sys.exit(0)
PY
  then
    log_audit "$JOB" "VALIDATE_FAIL agent=$agent — refusing to swap" >/dev/null
    rm -f "$tmp_db"
    fail=$((fail + 1))
    continue
  fi

  # Atomic rename. mv is atomic when src and dst are on the same filesystem.
  if mv -f "$tmp_db" "$live_db"; then
    log_audit "$JOB" "SWAPPED agent=$agent" >/dev/null
    ok=$((ok + 1))
  else
    log_audit "$JOB" "SWAP_FAIL agent=$agent" >/dev/null
    fail=$((fail + 1))
  fi
done < <(list_active_claude_agents)

log_audit "$JOB" "done ok=$ok fail=$fail skipped=$skipped" >/dev/null

if (( fail > 0 )); then
  file_failure_task "$JOB" "$LOG"
  # Exit non-zero only if every agent failed; otherwise partial success ships.
  if (( ok == 0 )); then
    exit 1
  fi
fi
exit 0
