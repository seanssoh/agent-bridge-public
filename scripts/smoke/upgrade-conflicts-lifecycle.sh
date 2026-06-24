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
#  3b. Issue #1653 (P1b): reconcile ALSO auto-archives when the live
#     target equals the recorded upstream blob AND the `.upgrade-conflict`
#     sidecar holds NO recoverable content (its bytes are byte-equal to
#     that upstream blob) — a spurious sidecar adopted to upstream. It
#     must NOT archive a GENUINE conflict (which also has live==upstream
#     the instant apply finishes, but whose sidecar holds the operator's
#     recoverable diff3/merge content that differs from upstream) — and
#     that content gate is immune to a later innocuous touch/re-save of
#     the live file. Still skips a pre-#1653 record that lacks the
#     upstream hash on a drifted live hash (no regression).
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
  # Args: <relpath> <live-content> <conflict-content> <run-id> [upstream-sha256]
  # The optional 5th arg records `upstream_target_sha256_at_write` (Issue
  # #1653) — the hash of the upstream blob the conflict was about, so the
  # reconcile legitimate-adopt branch can be exercised. Omit it to mimic a
  # pre-#1653 record that never carried the upstream hash.
  local relpath="$1"
  local live_content="$2"
  local conflict_content="$3"
  local run_id="$4"
  local upstream_sha="${5:-}"

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

  # Pass the optional upstream sha via env (FIXTURE_UPSTREAM_SHA) rather than
  # as a positional arg so the heredoc-opener line below stays byte-identical
  # to its baselined form (.lint-heredoc-baseline.tsv hash) — adding an argv
  # would shift the snippet hash and force a full baseline rewrite.
  FIXTURE_UPSTREAM_SHA="$upstream_sha" \
  python3 - "$record_path" "$run_id" "$conflict_path" "$live_path" "$relpath" "$live_sha" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

record_path, run_id, conflict, live, relpath, live_sha = sys.argv[1:]
Path(record_path).parent.mkdir(parents=True, exist_ok=True)
st = Path(conflict).stat()
entry = {
    "path": conflict,
    "live_target": live,
    "live_target_relpath": relpath,
    "size": st.st_size,
    "mtime": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).astimezone().isoformat(timespec="seconds"),
    "live_target_sha256_at_write": live_sha,
}
upstream_sha = os.environ.get("FIXTURE_UPSTREAM_SHA") or ""
if upstream_sha:
    entry["upstream_target_sha256_at_write"] = upstream_sha
payload = {
    "run_id": run_id,
    "timestamp": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
    "target_root": os.environ.get("BRIDGE_HOME"),
    "conflict_files": [entry],
}
Path(record_path).write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

sha256_of_string() {
  python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"
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

assert_auto_archive_when_legitimately_adopted() {
  # Issue #1653 (P1b): a SPURIOUS sidecar must be clearable once the file is
  # adopted to upstream. The spurious case (#1653: a clean file the prior
  # classifier mis-flagged, whose 3-way merge with base == live collapses to
  # upstream) leaves a sidecar that holds EXACTLY the upstream bytes — there
  # is nothing to recover. After a later clean adopt, live == upstream too.
  # Reconcile must clear it: live == upstream_target AND sidecar == upstream.
  #
  # The old reconcile (auto-archive only when live == at-write) could never
  # clear this — a clean adopt changes the live hash away from at-write — so
  # the sidecar stranded forever, especially on gated `hooks/` paths where
  # manual discard is blocked.
  #
  # Mutation-proof: before the fix the live != at-write branch falls to
  # "skip" → 1 pending. After the fix the sidecar==upstream branch archives
  # → 0 pending.
  drain_conflicts
  local relpath="hooks/bridge_hook_common.py"
  local upstream_content="adopted-upstream-blob-content"
  local upstream_sha
  upstream_sha="$(sha256_of_string "$upstream_content")"

  # Seed with the pre-adopt content as the at-write hash and the SPURIOUS
  # sidecar content == the upstream blob (nothing recoverable), recording the
  # upstream blob this conflict was about.
  seed_conflict_fixture "$relpath" "pre-adopt-live-content" "$upstream_content" "run-1653" "$upstream_sha"

  # The later clean adopt rewrote live to the upstream blob.
  printf '%s' "$upstream_content" >"$BRIDGE_HOME/$relpath"

  local before after archived reason
  before="$(count_conflicts_json)"
  smoke_assert_eq "1" "$before" "before reconcile: 1 stranded conflict"

  local recon
  recon="$(python3 "$UPGRADE_PY" conflicts-reconcile --target-root "$BRIDGE_HOME" --auto-archive)"
  archived="$(printf '%s' "$recon" | python3 -c 'import json, sys; print(json.load(sys.stdin)["archived_count"])')"
  smoke_assert_eq "1" "$archived" "reconcile auto-archives the spurious (sidecar==upstream) conflict"

  reason="$(printf '%s' "$recon" \
    | python3 -c 'import json, sys; a=json.load(sys.stdin)["actions"][0]; print(a["reason"])')"
  smoke_assert_contains "$reason" "no recoverable content" "reconcile reason names the no-recovery adopt case"

  after="$(count_conflicts_json)"
  smoke_assert_eq "0" "$after" "after reconcile: 0 pending conflicts (sidecar cleared)"

  # And the archive landed under backups/upgrade-conflict-archive/<date>/.
  local archive_root="$BRIDGE_HOME/backups/upgrade-conflict-archive"
  local found
  found="$(find "$archive_root" -type f -name 'bridge_hook_common.py.upgrade-conflict' | head -n 1)"
  [[ -n "$found" ]] || smoke_fail "adopted conflict not archived under $archive_root"
}

assert_skip_genuine_fresh_conflict_live_equals_upstream() {
  # Issue #1653 — the load-bearing false-positive guard (codex review catch):
  # a GENUINE unresolved merge conflict already has live == upstream the
  # instant apply finishes, because apply writes the upstream bytes to the
  # live target and parks the operator's RECOVERABLE content (diff3 markers /
  # operator bytes) in the sidecar. Reconcile must NOT archive it — doing so
  # would destroy the operator's pending recovery artifact. The tamper-proof
  # distinguisher is sidecar CONTENT: a genuine conflict's sidecar differs
  # from upstream, so the new branch must not fire even when live==upstream
  # and even if the live file is later touched/re-saved.
  #
  # Faithful state of a genuine fresh conflict:
  #   at_write     = the operator's PRE-apply content (!= upstream)
  #   live (now)   = the upstream blob (apply deployed it)
  #   sidecar      = operator/merge content (!= upstream) — RECOVERABLE
  #   upstream_tgt = sha(upstream blob)
  # `current != at_write` (skips branch 1); `current == upstream_target` but
  # `sidecar != upstream` so the new branch must NOT fire → skip.
  drain_conflicts
  local relpath="hooks/bridge_hook_common.py"
  local upstream_content="fresh-conflict-upstream-blob"
  local upstream_sha
  upstream_sha="$(sha256_of_string "$upstream_content")"

  # Sidecar holds genuine operator/merge content that differs from upstream.
  seed_conflict_fixture "$relpath" "operator-pre-apply-content" "<<<<<<< live\noperator-edit\n=======\nupstream-edit\n>>>>>>> upstream\n" "run-fresh" "$upstream_sha"

  # apply deployed the upstream blob to the live target.
  printf '%s' "$upstream_content" >"$BRIDGE_HOME/$relpath"

  # Adversarial: a later innocuous touch/re-save of the live file (still the
  # upstream bytes) must NOT flip the decision — content gate is immune.
  printf '%s' "$upstream_content" >"$BRIDGE_HOME/$relpath"

  local before after archived
  before="$(count_conflicts_json)"
  smoke_assert_eq "1" "$before" "before reconcile: 1 genuine pending conflict"

  local recon
  recon="$(python3 "$UPGRADE_PY" conflicts-reconcile --target-root "$BRIDGE_HOME" --auto-archive)"
  archived="$(printf '%s' "$recon" | python3 -c 'import json, sys; print(json.load(sys.stdin)["archived_count"])')"
  smoke_assert_eq "0" "$archived" "reconcile must NOT archive a genuine fresh conflict (sidecar holds recoverable content)"

  local decision
  decision="$(printf '%s' "$recon" \
    | python3 -c 'import json, sys; a=json.load(sys.stdin)["actions"][0]; print(a["decision"])')"
  smoke_assert_eq "skip" "$decision" "decision is skip for the genuine fresh conflict"

  after="$(count_conflicts_json)"
  smoke_assert_eq "1" "$after" "genuine conflict still pending after reconcile (recovery artifact preserved)"

  rm -f "$BRIDGE_HOME/$relpath.upgrade-conflict" "$BRIDGE_HOME/$relpath"
}

assert_skip_adopt_branch_for_pre_1653_record() {
  # Issue #1653: a pre-#1653 record (no upstream_target hash) must NOT be
  # affected by the new branch — only the existing at-write-equality branch
  # applies. With the live hash changed and no recorded upstream blob to
  # match, reconcile must still skip (no spurious archive, no regression).
  drain_conflicts
  seed_conflict_fixture "lib/bridge-state.sh" "live-pre1653-original" "conflict-pre1653" "run-1653b"
  printf '%s' "live-pre1653-changed-but-not-upstream" >"$BRIDGE_HOME/lib/bridge-state.sh"

  local archived after
  archived="$(python3 "$UPGRADE_PY" conflicts-reconcile --target-root "$BRIDGE_HOME" --auto-archive \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["archived_count"])')"
  smoke_assert_eq "0" "$archived" "pre-#1653 record (no upstream hash) is not auto-archived on a drifted live hash"

  after="$(count_conflicts_json)"
  smoke_assert_eq "1" "$after" "pre-#1653 conflict still pending (no regression to the skip path)"

  rm -f "$BRIDGE_HOME/lib/bridge-state.sh.upgrade-conflict"
  rm -f "$BRIDGE_HOME/lib/bridge-state.sh"
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

  # The pending upgrade-conflict count is an audit-parse / fs-scan analytic
  # deferred behind `--full` (status-fast-default): the default human
  # dashboard skips it, so the warning line only renders with `--full`.
  local plain
  plain="$(python3 "$STATUS_PY" \
    --roster-snapshot "$roster_snap" \
    --db "$BRIDGE_TASK_DB" \
    --daemon-pid-file "$BRIDGE_HOME/state/daemon.pid" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --bridge-home "$BRIDGE_HOME" \
    --audit-log "$BRIDGE_AUDIT_LOG" \
    --full)"
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
  smoke_run "reconcile auto-archives a spurious (sidecar==upstream) adopted conflict (#1653)" assert_auto_archive_when_legitimately_adopted
  smoke_run "reconcile skips a GENUINE conflict whose sidecar holds recoverable content (#1653 FP guard)" assert_skip_genuine_fresh_conflict_live_equals_upstream
  smoke_run "reconcile skips a pre-#1653 record on a drifted hash (no regression)" assert_skip_adopt_branch_for_pre_1653_record
  smoke_run "adopt replaces live target and removes conflict" assert_adopt_replaces_live_and_removes_conflict
  smoke_run "discard removes conflict, live unchanged" assert_discard_removes_conflict_only
  smoke_run "archive moves conflict to backups/upgrade-conflict-archive/<date>/" assert_archive_moves_conflict
  smoke_run "diff emits a unified diff and exits 0 on differences" assert_diff_emits_unified_diff
  smoke_run "bridge-status surfaces the pending count + WARNING line" assert_status_warning_surface
  smoke_run "adopt/discard/archive without --yes and no TTY refuses with a clear message" assert_no_yes_no_tty_rejects
  smoke_log "passed"
}

main "$@"
