#!/usr/bin/env bash
# scripts/smoke/upgrade-conflicts-lifecycle.sh — Issue #394 smoke.
#
# Validates the lifecycle/sweep tooling for `*.upgrade-conflict` files
# left behind by 3-way merges in `agb upgrade --apply`:
#  1. Conflict-write + structured record: a fixture .upgrade-conflict
#     file plus its state/upgrade-conflicts/<run-id>.json entry is
#     visible via `conflicts list --json`.
#  2. Auto-archive when the live target hash hasn't changed since the
#     conflict was written: reconcile moves the file under
#     backups/upgrade-conflict-archive/<date>/.
#  3. Reconcile skips the auto-archive when the live target hash has
#     changed (operator may be mid-reconcile).
#  4. `conflicts adopt` replaces the live target with conflict content
#     and removes the conflict file.
#  5. `conflicts discard` removes the conflict file but leaves the
#     live target intact.
#  6. `conflicts archive` (manual) moves the conflict under
#     backups/upgrade-conflict-archive/<date>/ regardless of hash.
#  7. `conflicts diff` emits a unified diff of live vs conflict and
#     exits 0 even when the two files differ (since `diff -u` returns 1
#     on differences, which the handler remaps to 0).
#  8. `bridge-status.py --json` exposes the pending count via
#     `pending_upgrade_conflicts`.
#  9. adopt/discard/archive without --yes and without TTY refuses with
#     a clear message and a non-zero exit.
#
# Uses BRIDGE_HOME isolation (mktemp -d) and never touches operator
# live runtime.

set -euo pipefail

SMOKE_NAME="upgrade-conflicts-lifecycle"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

UPGRADE_PY=""
STATUS_PY=""

# ---- helpers ---------------------------------------------------------

seed_conflict_fixture() {
  # Creates one live target + one conflict file + one structured-record
  # entry whose at-write sha matches the *live target's* current sha,
  # so `conflicts reconcile` should treat it as auto-archive eligible.
  #
  # Args: <relpath> <live-content> <conflict-content> <run-id>
  local relpath="$1"
  local live_content="$2"
  local conflict_content="$3"
  local run_id="$4"

  local live_path="$BRIDGE_HOME/$relpath"
  local conflict_path="$live_path.upgrade-conflict"
  local record_path="$BRIDGE_HOME/state/upgrade-conflicts/${run_id}.json"

  mkdir -p "$(dirname "$live_path")"
  printf '%s' "$live_content" >"$live_path"
  printf '%s' "$conflict_content" >"$conflict_path"

  local live_sha
  live_sha="$(python3 -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "$live_path")"

  python3 - "$record_path" "$run_id" "$conflict_path" "$live_path" "$relpath" "$live_sha" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

record_path, run_id, conflict, live, relpath, live_sha = sys.argv[1:]
Path(record_path).parent.mkdir(parents=True, exist_ok=True)
st = Path(conflict).stat()
payload = {
    "run_id": run_id,
    "timestamp": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
    "target_root": os.environ.get("BRIDGE_HOME"),
    "conflict_files": [
        {
            "path": conflict,
            "live_target": live,
            "live_target_relpath": relpath,
            "size": st.st_size,
            "mtime": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).astimezone().isoformat(timespec="seconds"),
            "live_target_sha256_at_write": live_sha,
        }
    ],
}
Path(record_path).write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

count_conflicts_json() {
  python3 "$UPGRADE_PY" conflicts-list --target-root "$BRIDGE_HOME" --json \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["count"])'
}

# ---- assertions ------------------------------------------------------

drain_conflicts() {
  # Remove all *.upgrade-conflict files under BRIDGE_HOME (excluding
  # archives) and wipe state/upgrade-conflicts/ records so each
  # assertion starts from a known-empty conflict surface.
  find "$BRIDGE_HOME" -type f -name '*.upgrade-conflict' -not -path "$BRIDGE_HOME/backups/*" -delete 2>/dev/null || true
  rm -rf "$BRIDGE_HOME/state/upgrade-conflicts"
}

assert_conflict_record_listed() {
  drain_conflicts
  seed_conflict_fixture "agents/_template/CLAUDE.md" "live-content-A" "conflict-content-A" "run-A"
  local count
  count="$(count_conflicts_json)"
  smoke_assert_eq "1" "$count" "list --json reports 1 pending conflict"

  local row_path
  row_path="$(python3 "$UPGRADE_PY" conflicts-list --target-root "$BRIDGE_HOME" --json \
    | python3 -c 'import json, sys; rows = json.load(sys.stdin)["conflicts"]; print(rows[0]["path"])')"
  smoke_assert_contains "$row_path" "agents/_template/CLAUDE.md.upgrade-conflict" "list path correct"
}

assert_auto_archive_when_unchanged() {
  drain_conflicts
  # Fresh fixture so the at-write hash matches the current live target.
  seed_conflict_fixture "scripts/smoke-test.sh" "live-X-stable" "conflict-X" "run-B"
  local before after archived
  before="$(count_conflicts_json)"
  smoke_assert_eq "1" "$before" "before reconcile: 1 conflict"

  archived="$(python3 "$UPGRADE_PY" conflicts-reconcile --target-root "$BRIDGE_HOME" --auto-archive \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["archived_count"])')"
  smoke_assert_eq "1" "$archived" "reconcile auto-archives the unchanged-hash conflict"

  after="$(count_conflicts_json)"
  smoke_assert_eq "0" "$after" "after reconcile: 0 pending conflicts"

  local archive_root="$BRIDGE_HOME/backups/upgrade-conflict-archive"
  [[ -d "$archive_root" ]] || smoke_fail "archive root missing: $archive_root"
  local archived_path
  archived_path="$(find "$archive_root" -type f -name '*.upgrade-conflict' | head -n 1)"
  [[ -n "$archived_path" ]] || smoke_fail "expected archived conflict under $archive_root"
}

assert_skip_auto_archive_when_changed() {
  drain_conflicts
  seed_conflict_fixture "scripts/install.sh" "live-Y-original" "conflict-Y" "run-C"
  # Mutate the live target so its current hash diverges from the
  # at-write hash recorded in run-C.json.
  printf '%s' "live-Y-changed" >"$BRIDGE_HOME/scripts/install.sh"

  local before after archived
  before="$(count_conflicts_json)"
  smoke_assert_eq "1" "$before" "before reconcile: 1 conflict"

  archived="$(python3 "$UPGRADE_PY" conflicts-reconcile --target-root "$BRIDGE_HOME" --auto-archive \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["archived_count"])')"
  smoke_assert_eq "0" "$archived" "reconcile leaves changed-hash conflict alone"

  after="$(count_conflicts_json)"
  smoke_assert_eq "1" "$after" "conflict still pending after reconcile (operator may be mid-reconcile)"

  # Drain for the next assertion.
  rm -f "$BRIDGE_HOME/scripts/install.sh.upgrade-conflict"
  rm -f "$BRIDGE_HOME/scripts/install.sh"
}

assert_adopt_replaces_live_and_removes_conflict() {
  drain_conflicts
  seed_conflict_fixture "agents/.claude/settings.json" '{"k":"live"}' '{"k":"adopted"}' "run-D"
  local live_path="$BRIDGE_HOME/agents/.claude/settings.json"
  local conflict_path="$live_path.upgrade-conflict"

  python3 "$UPGRADE_PY" conflicts-adopt --target-root "$BRIDGE_HOME" --yes "$conflict_path" >/dev/null
  [[ -f "$conflict_path" ]] && smoke_fail "conflict file should be removed after adopt"
  local content
  content="$(cat "$live_path")"
  smoke_assert_eq '{"k":"adopted"}' "$content" "live target replaced with conflict content"
}

assert_discard_removes_conflict_only() {
  drain_conflicts
  seed_conflict_fixture "agents/_template/MEMORY-SCHEMA.md" "live-Z" "conflict-Z" "run-E"
  local live_path="$BRIDGE_HOME/agents/_template/MEMORY-SCHEMA.md"
  local conflict_path="$live_path.upgrade-conflict"

  python3 "$UPGRADE_PY" conflicts-discard --target-root "$BRIDGE_HOME" --yes "$conflict_path" >/dev/null
  [[ -f "$conflict_path" ]] && smoke_fail "conflict file should be removed after discard"
  local content
  content="$(cat "$live_path")"
  smoke_assert_eq "live-Z" "$content" "live target unchanged after discard"
}

assert_archive_moves_conflict() {
  drain_conflicts
  seed_conflict_fixture "bootstrap-memory-system.sh" "live-W" "conflict-W" "run-F"
  local live_path="$BRIDGE_HOME/bootstrap-memory-system.sh"
  local conflict_path="$live_path.upgrade-conflict"

  python3 "$UPGRADE_PY" conflicts-archive --target-root "$BRIDGE_HOME" --yes "$conflict_path" >/dev/null
  [[ -f "$conflict_path" ]] && smoke_fail "conflict file should not remain in live tree after archive"
  local content
  content="$(cat "$live_path")"
  smoke_assert_eq "live-W" "$content" "live target unchanged after archive"

  # The archive should land under backups/upgrade-conflict-archive/<date>/.
  local archive_root="$BRIDGE_HOME/backups/upgrade-conflict-archive"
  local found
  found="$(find "$archive_root" -type f -name 'bootstrap-memory-system.sh.upgrade-conflict' | head -n 1)"
  [[ -n "$found" ]] || smoke_fail "archived conflict not found under $archive_root"
}

assert_diff_emits_unified_diff() {
  drain_conflicts
  seed_conflict_fixture "agents/_template/CLAUDE.md" "live-line-1
live-line-2
" "conflict-line-1
conflict-line-2
" "run-G"
  local conflict_path="$BRIDGE_HOME/agents/_template/CLAUDE.md.upgrade-conflict"

  local rc=0
  local out
  # `diff -u` exits 1 on differences; cmd_conflicts_diff remaps that to 0.
  out="$(python3 "$UPGRADE_PY" conflicts-diff --target-root "$BRIDGE_HOME" "$conflict_path")" || rc=$?
  [[ "$rc" -eq 0 ]] || smoke_fail "conflicts-diff should exit 0 even when files differ (got rc=$rc)"
  smoke_assert_contains "$out" "---" "diff output contains unified-diff header for live target"
  smoke_assert_contains "$out" "+++" "diff output contains unified-diff header for conflict file"
  smoke_assert_contains "$out" "-live-line-1" "diff output marks the live-only line with -"
  smoke_assert_contains "$out" "+conflict-line-1" "diff output marks the conflict-only line with +"
}

assert_status_warning_surface() {
  # Reset to a known set of 3 pending conflicts for a deterministic count.
  # `${BRIDGE_HOME:?}` guard so a misconfigured env never expands to /*.
  rm -rf "${BRIDGE_HOME:?}"/* "${BRIDGE_HOME:?}"/.[!.]* 2>/dev/null || true
  mkdir -p \
    "$BRIDGE_STATE_DIR" \
    "$BRIDGE_LOG_DIR" \
    "$BRIDGE_AGENT_HOME_ROOT"
  : >"$BRIDGE_ROSTER_FILE"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  # Seed an empty queue DB so bridge-status.py's queue path is happy.
  python3 - "$BRIDGE_TASK_DB" <<'PY'
import sqlite3, sys, pathlib
path = sys.argv[1]
pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(path)
conn.executescript("""
CREATE TABLE IF NOT EXISTS tasks(
  id INTEGER PRIMARY KEY,
  assigned_to TEXT,
  created_by TEXT,
  claimed_by TEXT,
  title TEXT,
  status TEXT,
  priority TEXT,
  updated_ts INTEGER,
  lease_until_ts INTEGER
);
CREATE TABLE IF NOT EXISTS agent_state(
  agent TEXT PRIMARY KEY,
  active INTEGER DEFAULT 0,
  last_seen_ts INTEGER,
  last_heartbeat_ts INTEGER,
  session_activity_ts INTEGER,
  last_nudge_ts INTEGER
);
""")
# Roster snapshot needs a header row even if no agents exist.
conn.commit()
conn.close()
PY
  # Roster snapshot stub with a header but no agent rows.
  local roster_snap
  roster_snap="$(mktemp)"
  printf 'agent\tengine\tworkdir\tactive\twake\tchannels\tloop\tsource\tactivity_state\n' >"$roster_snap"

  # Three pending conflict files (no structured record needed for the count surface).
  for relpath in "agents/--help/CLAUDE.md" "agents/_template/session-types/admin.md" "scripts/smoke-test.sh"; do
    mkdir -p "$BRIDGE_HOME/$(dirname "$relpath")"
    : >"$BRIDGE_HOME/$relpath"
    : >"$BRIDGE_HOME/$relpath.upgrade-conflict"
  done

  local plain
  plain="$(python3 "$STATUS_PY" \
    --roster-snapshot "$roster_snap" \
    --db "$BRIDGE_TASK_DB" \
    --daemon-pid-file "$BRIDGE_HOME/state/daemon.pid" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --bridge-home "$BRIDGE_HOME" \
    --audit-log "$BRIDGE_AUDIT_LOG")"
  rm -f "$roster_snap"
  smoke_assert_contains "$plain" "WARNING: 3 pending upgrade-conflict file(s)" "warning line emitted"
  smoke_assert_contains "$plain" "agent-bridge upgrade conflicts list" "warning points to list subcommand"

  # JSON path also surfaces the count.
  roster_snap="$(mktemp)"
  printf 'agent\tengine\tworkdir\tactive\twake\tchannels\tloop\tsource\tactivity_state\n' >"$roster_snap"
  local json
  json="$(python3 "$STATUS_PY" \
    --roster-snapshot "$roster_snap" \
    --db "$BRIDGE_TASK_DB" \
    --daemon-pid-file "$BRIDGE_HOME/state/daemon.pid" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --bridge-home "$BRIDGE_HOME" \
    --audit-log "$BRIDGE_AUDIT_LOG" \
    --json)"
  rm -f "$roster_snap"
  local parsed
  parsed="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending_upgrade_conflicts"])')"
  smoke_assert_eq "3" "$parsed" "JSON dashboard exposes pending_upgrade_conflicts=3"
}

assert_no_yes_no_tty_rejects() {
  # Re-seed a single conflict (status-warning test wiped the home).
  local relpath="agents/_template/CLAUDE.md"
  mkdir -p "$BRIDGE_HOME/$(dirname "$relpath")"
  : >"$BRIDGE_HOME/$relpath"
  : >"$BRIDGE_HOME/$relpath.upgrade-conflict"
  local conflict_path="$BRIDGE_HOME/$relpath.upgrade-conflict"

  # Run without --yes and pipe stdin from /dev/null so isatty() is False.
  local rc=0
  local err
  err="$(python3 "$UPGRADE_PY" conflicts-discard --target-root "$BRIDGE_HOME" "$conflict_path" \
    </dev/null 2>&1 1>/dev/null)" || rc=$?
  smoke_assert_contains "$err" "refusing without confirmation" "discard without --yes prints a clear refusal"
  [[ "$rc" -ne 0 ]] || smoke_fail "discard without --yes should exit non-zero"

  # The conflict file must still be present.
  [[ -f "$conflict_path" ]] || smoke_fail "discard without confirmation must not delete the conflict file"

  # adopt also rejects.
  rc=0
  err="$(python3 "$UPGRADE_PY" conflicts-adopt --target-root "$BRIDGE_HOME" "$conflict_path" \
    </dev/null 2>&1 1>/dev/null)" || rc=$?
  smoke_assert_contains "$err" "refusing without confirmation" "adopt without --yes prints a clear refusal"
  [[ "$rc" -ne 0 ]] || smoke_fail "adopt without --yes should exit non-zero"

  # archive also rejects (mirrors discard/adopt).
  rc=0
  err="$(python3 "$UPGRADE_PY" conflicts-archive --target-root "$BRIDGE_HOME" "$conflict_path" \
    </dev/null 2>&1 1>/dev/null)" || rc=$?
  smoke_assert_contains "$err" "refusing without confirmation" "archive without --yes prints a clear refusal"
  [[ "$rc" -ne 0 ]] || smoke_fail "archive without --yes should exit non-zero"
  [[ -f "$conflict_path" ]] || smoke_fail "archive without confirmation must not move the conflict file"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "upgrade-conflicts-lifecycle"
  UPGRADE_PY="$SMOKE_REPO_ROOT/bridge-upgrade.py"
  STATUS_PY="$SMOKE_REPO_ROOT/bridge-status.py"

  smoke_run "list --json reports the seeded conflict + structured record" assert_conflict_record_listed
  smoke_run "reconcile auto-archives when live hash unchanged" assert_auto_archive_when_unchanged
  smoke_run "reconcile skips when live hash changed" assert_skip_auto_archive_when_changed
  smoke_run "adopt replaces live target and removes conflict" assert_adopt_replaces_live_and_removes_conflict
  smoke_run "discard removes conflict, live unchanged" assert_discard_removes_conflict_only
  smoke_run "archive moves conflict to backups/upgrade-conflict-archive/<date>/" assert_archive_moves_conflict
  smoke_run "diff emits a unified diff and exits 0 on differences" assert_diff_emits_unified_diff
  smoke_run "bridge-status surfaces the pending count + WARNING line" assert_status_warning_surface
  smoke_run "adopt/discard/archive without --yes and no TTY refuses with a clear message" assert_no_yes_no_tty_rejects
  smoke_log "passed"
}

main "$@"
