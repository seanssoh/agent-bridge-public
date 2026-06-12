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

# Issue #1827 (read-side sibling of #1222): the per-agent rebuild below
# writes into `$home/memory/` — `mkdir -p`, the lock file, `rm -f tmp_db`,
# `bridge-memory.py rebuild-index --db-path tmp_db`, and the final
# `mv -f tmp_db live_db`. Under linux-user isolation that dir is owned by
# the iso UID with group `ab-agent-<slug>` mode 2770; the controller is
# intentionally NOT in that group (per the v2 contract), so every one of
# those controller-side ops fails with `Permission denied` and each iso
# agent lands in the `fail`/`skipped` tally — a recurring, noisy
# per-agent failure on every run, even though the only impact is a stale
# index.
#
# Fix (unify with #1222's resolution): drop to the iso UID via
# `bridge_isolation_run_as_agent_user_via_bash` for the entire rebuild
# block so the writes happen inside the boundary. Do NOT relax the
# 2770 iso perms — the isolation boundary must hold. Non-isolated
# (shared/legacy) agents keep the controller-direct path unchanged.
#
# Sourcing bridge-lib.sh pulls in bridge-agents.sh
# (`bridge_agent_linux_user_isolation_effective` + `bridge_agent_os_user`)
# and bridge-isolation-helpers.sh
# (`bridge_isolation_run_as_agent_user_via_bash`). The source is guarded
# so a stripped install (or smoke harness with a minimal $BRIDGE_HOME)
# still runs the non-iso path. `_BRIDGE_ISO_HELPERS_LOADED` records
# whether the iso path is available.
#
# IMPORTANT (#1222 codex r1 finding, carried here): merely sourcing
# bridge-lib.sh does NOT populate the per-agent assoc arrays
# (`BRIDGE_AGENT_ISOLATION_MODE`, `BRIDGE_AGENT_OS_USER`, …) the predicate
# reads — those are filled by `bridge_load_roster` from
# `lib/bridge-state.sh`. Without that call every iso agent's predicate
# returns false in this shell and the rebuild falls back to the
# controller-direct path that hits the `Permission denied` shape (#1827).
# So: source, verify the helpers AND the roster loader exist, then load.
_BRIDGE_ISO_HELPERS_LOADED=0
if [[ -r "$HERE/../bridge-lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HERE/../bridge-lib.sh" || true
  if declare -F bridge_isolation_run_as_agent_user_via_bash >/dev/null 2>&1 \
      && declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && declare -F bridge_load_roster >/dev/null 2>&1 \
      && bridge_load_roster >/dev/null 2>&1; then
    _BRIDGE_ISO_HELPERS_LOADED=1
  fi
fi

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

  # Issue #1827: under linux-user isolation the whole rebuild/publish
  # block below writes into the iso-owned `memory/` dir (mode 2770
  # `agent-bridge-<slug>:ab-agent-<slug>`), which the controller cannot
  # mkdir/lock/rm/rebuild/mv into. Run the entire block as the iso UID via
  # the sanctioned run-as helper (matches #1222's resolution). On a
  # non-isolated (shared/legacy) agent this gate is false and the
  # controller-direct path below runs unchanged.
  _iso_isolated=0
  if (( _BRIDGE_ISO_HELPERS_LOADED == 1 )) \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    _iso_isolated=1
  fi

  if (( _iso_isolated == 1 )); then
    # Self-contained inline rebuild run as the iso UID via the sudoers
    # `bash` allowlist. Does NOT source bridge-lib.sh inside the isolated
    # UID (the allowlist is `bash` + `tmux` only). The body is a
    # single-quoted string so $vars resolve only inside the sudo'd bash.
    #
    # Args bound inside the script:
    #   $1 = BRIDGE_PYTHON, $2 = BRIDGE_HOME, $3 = agent, $4 = home,
    #   $5 = shared_root, $6 = live_db, $7 = tmp_db, $8 = lock_file
    #
    # Script exit codes (all 0 or >= 10 so the wrapper's +2 shift on
    # script rc<3 never collides with the wrapper's own 0/1/2 pre-flight
    # band — see bridge_isolation_run_as_agent_user_via_bash):
    #   0  — full rebuild + validate + swap succeeded
    #   10 — memory/ mkdir failed (true ACL/mode drift inside the iso tree)
    #   11 — lock contended/init failed
    #   12 — stale tmp_db unlink failed
    #   13 — rebuild-index invocation failed
    #   14 — validate failed (wrong/empty DB); script removes tmp_db
    #   15 — mktemp for the validate harness failed
    #   16 — final mv tmp_db -> live_db failed
    #
    # Footgun #11 (heredoc-stdin deadlock): NO `<<EOF` / `<<<` / `<<'PY'`
    # anywhere in this body. The lock + validate python harnesses are
    # written to tmp files inside the iso-owned memory/ dir with printf,
    # then run via `python3 -- <file>` — never fed on stdin.
    _iso_rebuild_script='
bridge_python="$1"
bridge_home="$2"
agent="$3"
home="$4"
shared_root="$5"
live_db="$6"
tmp_db="$7"
lock_file="$8"

# Phase 0: ensure memory/ parent dir exists (as the iso UID).
if ! mkdir -p "$(dirname "$live_db")"; then
  exit 10
fi

# Phase 1: lock helper staged inside the iso-owned memory/ dir, then run
# via `python3 -- file` (no heredoc stdin). Non-blocking first, then
# block up to 30s; exit 11 on contention/IO failure. This mirrors the
# legacy non-iso path exactly: a best-effort acquire-assert-release
# interlock against a concurrent manual rebuild (the lock is released
# when the python proc exits, before rebuild/publish — same as legacy).
lock_dir="$(dirname "$lock_file")"
lock_py="$(mktemp "$lock_dir/.wiki-v2-lock.XXXXXX.py")" || exit 11
trap "rm -f \"$lock_py\" 2>/dev/null" EXIT INT TERM
{
  printf "%s\n" "import fcntl, sys, time"
  printf "%s\n" "path = sys.argv[1]"
  printf "%s\n" "f = open(path, \"a+\")"
  printf "%s\n" "start = time.time()"
  printf "%s\n" "while True:"
  printf "%s\n" "    try:"
  printf "%s\n" "        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); break"
  printf "%s\n" "    except BlockingIOError:"
  printf "%s\n" "        if time.time() - start > 30: sys.exit(11)"
  printf "%s\n" "        time.sleep(1)"
  printf "%s\n" "sys.exit(0)"
} >"$lock_py" || exit 11
if ! "$bridge_python" "$lock_py" "$lock_file"; then
  exit 11
fi

# Phase 2: clear stale tmp DB from a previous abort.
if [[ -e "$tmp_db" ]] && ! rm -f "$tmp_db"; then
  exit 12
fi

# Phase 3: run rebuild-index. Cap with timeout when available.
rebuild_rc=0
if command -v timeout >/dev/null 2>&1; then
  timeout 900 "$bridge_python" "$bridge_home/bridge-memory.py" rebuild-index \
    --agent "$agent" --home "$home" \
    --bridge-home "$bridge_home" \
    --index-kind bridge-wiki-hybrid-v2 \
    --shared-root "$shared_root" \
    --db-path "$tmp_db" \
    --json \
    >/dev/null 2>&1 || rebuild_rc=$?
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout 900 "$bridge_python" "$bridge_home/bridge-memory.py" rebuild-index \
    --agent "$agent" --home "$home" \
    --bridge-home "$bridge_home" \
    --index-kind bridge-wiki-hybrid-v2 \
    --shared-root "$shared_root" \
    --db-path "$tmp_db" \
    --json \
    >/dev/null 2>&1 || rebuild_rc=$?
else
  "$bridge_python" "$bridge_home/bridge-memory.py" rebuild-index \
    --agent "$agent" --home "$home" \
    --bridge-home "$bridge_home" \
    --index-kind bridge-wiki-hybrid-v2 \
    --shared-root "$shared_root" \
    --db-path "$tmp_db" \
    --json \
    >/dev/null 2>&1 || rebuild_rc=$?
fi
if [[ "$rebuild_rc" -ne 0 ]]; then
  exit 13
fi

# Phase 4: validate tmp_db via a python harness staged in the iso-owned
# memory/ dir (printf -> file, then `python3 -- file`).
validate_py="$(mktemp "$lock_dir/.wiki-v2-validate.XXXXXX.py")" || exit 15
trap "rm -f \"$lock_py\" \"$validate_py\" 2>/dev/null" EXIT INT TERM
{
  printf "%s\n" "import sqlite3, sys"
  printf "%s\n" "p = sys.argv[1]"
  printf "%s\n" "con = sqlite3.connect(p); cur = con.cursor()"
  printf "%s\n" "cur.execute(\"SELECT value FROM meta WHERE key=\x27index_kind\x27\")"
  printf "%s\n" "r = cur.fetchone()"
  printf "%s\n" "kind = r[0] if r else \"\""
  printf "%s\n" "cur.execute(\"SELECT COUNT(*) FROM chunks\")"
  printf "%s\n" "chunks = cur.fetchone()[0]"
  printf "%s\n" "con.close()"
  printf "%s\n" "sys.exit(0 if (kind == \"bridge-wiki-hybrid-v2\" and chunks > 0) else 1)"
} >"$validate_py" || exit 15
if ! "$bridge_python" "$validate_py" "$tmp_db"; then
  rm -f "$tmp_db" 2>/dev/null
  exit 14
fi

# Phase 5: atomic swap.
if ! mv -f "$tmp_db" "$live_db"; then
  exit 16
fi
exit 0
'
    _iso_rc=0
    bridge_isolation_run_as_agent_user_via_bash "$agent" "$_iso_rebuild_script" \
      "$BRIDGE_PYTHON" "$BRIDGE_HOME" "$agent" "$home" \
      "$BRIDGE_SHARED_ROOT" "$live_db" "$tmp_db" "$lock_file" 2>/dev/null || _iso_rc=$?
    case "$_iso_rc" in
      0)
        log_audit "$JOB" "SWAPPED agent=$agent (iso-uid)" >/dev/null
        ok=$((ok + 1))
        ;;
      2)
        # Sudo unavailable / passwordless sudoers missing. The iso v2
        # contract requires it — count as skipped (not a rebuild failure)
        # with an informational line, not per-agent ERROR spam.
        log_audit "$JOB" "ISO_SUDO_UNAVAILABLE skip agent=$agent" >/dev/null
        skipped=$((skipped + 1))
        ;;
      1)
        # rc=1 means the helper's own isolation re-check disagreed with
        # our gate (roster/state drift). Skip with an info line.
        log_audit "$JOB" "ISO_GATE_INCONSISTENT skip agent=$agent" >/dev/null
        skipped=$((skipped + 1))
        ;;
      11)
        log_audit "$JOB" "LOCK_BUSY skip agent=$agent (iso-uid)" >/dev/null
        skipped=$((skipped + 1))
        ;;
      *)
        log_audit "$JOB" "FAIL($_iso_rc) rebuild agent=$agent (iso-uid)" >/dev/null
        fail=$((fail + 1))
        ;;
    esac
    continue
  fi

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
