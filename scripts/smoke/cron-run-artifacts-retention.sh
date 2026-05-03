#!/usr/bin/env bash
# scripts/smoke/cron-run-artifacts-retention.sh — Issue #533 smoke.
#
# Validates the new `cleanup --mode run-artifacts` retention/GC pass:
#  1. report --dry-run reports the expected eligibility for seeded fixtures.
#  2. prune actually deletes eligible entries.
#  3. always-preserve floor: with 10 entries for a single cron-family all
#     older than retention, top 5 are preserved.
#  4. combined deletion gate skips runs whose:
#     - queue status is non-terminal (claimed),
#     - status.json is non-terminal (failed-run state="error" honors
#       Tier-B but is still kept on Tier-A surfaces because the longer
#       Tier-B clock applies),
#     - argv references the run_id (live PID liveness anchor).
#  5. symlink safety: a fixture entry replaced with a symlink to /etc/passwd
#     is never followed, /etc/passwd is intact.
#  6. dry-run does not mutate.
#  7. backwards compat: --mode one-shot / expired-one-shot still works
#     (rewrites jobs.json correctly; this is the path that ran before #533).
#  8. foreign-install isolation: a `sleep` whose argv mentions a run_id
#     but is rooted under a different prefix does NOT match the
#     path-anchored matcher.
#
# This smoke uses BRIDGE_HOME isolation (mktemp -d) and never touches the
# operator's live runtime.

set -euo pipefail

SMOKE_NAME="cron-run-artifacts-retention"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

PY_BIN="${PYTHON3:-python3}"
SPAWNED_PIDS=()

cleanup() {
  local pid
  for pid in "${SPAWNED_PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  SPAWNED_PIDS=()
  smoke_cleanup_temp_root
}
trap cleanup EXIT

now_minus_days_seconds() {
  local days="$1"
  python3 -c "import sys, time; print(int(time.time()) - int(sys.argv[1]) * 86400)" "$days"
}

# Touch a path's mtime to <days> ago.
backdate() {
  local path="$1"
  local days="$2"
  local target_ts
  target_ts="$(now_minus_days_seconds "$days")"
  python3 - "$path" "$target_ts" <<'PY'
import os, sys
path = sys.argv[1]
ts = int(sys.argv[2])
os.utime(path, (ts, ts))
PY
}

seed_tasks_db() {
  python3 - "$BRIDGE_TASK_DB" <<'PY'
import sqlite3, sys
path = sys.argv[1]
import pathlib
pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(path)
conn.execute(
    """
    CREATE TABLE IF NOT EXISTS tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        status TEXT NOT NULL DEFAULT 'queued'
    )
    """
)
conn.commit()
conn.close()
PY
}

insert_task() {
  local status="$1"
  python3 - "$BRIDGE_TASK_DB" "$status" <<'PY'
import sqlite3, sys
path, status = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(path)
cur = conn.execute("INSERT INTO tasks (status) VALUES (?)", (status,))
print(cur.lastrowid)
conn.commit()
conn.close()
PY
}

seed_floor_padding() {
  # Seed N=5 padding fixtures in a given cron-family so the test's single
  # entry of interest does NOT get pinned by the always-preserve floor.
  # Padding entries are 8 days old (just past Tier-A 7d retention, so
  # they remain eligible-by-age) and they MUST be newer than the test
  # entry's mtime so the floor-by-mtime-DESC sort picks padding ahead of
  # the test entry. Caller writes its test entry first, then we pad.
  local family_prefix="$1"
  local i task_id
  for i in 91 92 93 94 95; do
    task_id="$(insert_task done)"
    write_run_fixture "${family_prefix}--padslot${i}" "$task_id" "success" 8
  done
}

write_run_fixture() {
  # Args: run_id, dispatch_task_id, run_state, days_old
  local run_id="$1"
  local dispatch_task_id="$2"
  local run_state="$3"
  local days_old="$4"
  local run_dir="$BRIDGE_STATE_DIR/cron/runs/$run_id"
  mkdir -p "$run_dir"
  cat >"$run_dir/request.json" <<EOF
{"run_id": "$run_id", "dispatch_task_id": $dispatch_task_id, "job_id": "job-${run_id}", "job_name": "morning-briefing-${run_id}"}
EOF
  cat >"$run_dir/payload.md" <<EOF
[fixture payload for $run_id]
EOF
  cat >"$run_dir/status.json" <<EOF
{"run_id": "$run_id", "state": "$run_state"}
EOF
  cat >"$run_dir/result.json" <<EOF
{"status": "$run_state"}
EOF
  : >"$run_dir/stdout.log"
  : >"$run_dir/stderr.log"
  backdate "$run_dir" "$days_old"
  backdate "$run_dir/status.json" "$days_old"
  backdate "$run_dir/request.json" "$days_old"
  backdate "$run_dir/payload.md" "$days_old"
  # Write paired shared/cron-* artifacts so we can assert all 6 surfaces.
  local dispatch_md="$BRIDGE_SHARED_DIR/cron-dispatch/$run_id.md"
  local result_md="$BRIDGE_SHARED_DIR/cron-result/$run_id.md"
  local followup_md="$BRIDGE_SHARED_DIR/cron-followup/$run_id.md"
  mkdir -p "$BRIDGE_SHARED_DIR/cron-dispatch" "$BRIDGE_SHARED_DIR/cron-result" "$BRIDGE_SHARED_DIR/cron-followup"
  : >"$dispatch_md"
  : >"$result_md"
  : >"$followup_md"
  backdate "$dispatch_md" "$days_old"
  backdate "$result_md" "$days_old"
  backdate "$followup_md" "$days_old"
  # Worker log keyed by queue task id.
  local worker_log="$BRIDGE_STATE_DIR/cron/workers/task-${dispatch_task_id}.log"
  mkdir -p "$BRIDGE_STATE_DIR/cron/workers"
  : >"$worker_log"
  backdate "$worker_log" "$days_old"
}

run_py() {
  python3 "$SMOKE_REPO_ROOT/bridge-cron.py" "$@"
}

assert_basic_dry_run_report() {
  local out
  out="$(run_py cleanup-report --mode run-artifacts \
    --target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB" --json)"
  smoke_assert_contains "$out" '"mode": "run-artifacts"' "report mode echoed"
  smoke_assert_contains "$out" '"tier_a_days": 7' "default tier_a_days emitted"
  smoke_assert_contains "$out" '"tier_b_days": 30' "default tier_b_days emitted"
  smoke_assert_contains "$out" '"always_preserve_floor": 5' "preserve floor emitted"
}

assert_eligible_runs_get_pruned() {
  # Seed 6 entries (>= floor+1) so at least 1 entry is eligible after the
  # always-preserve floor.  All 6 share a cron-family, all >7d old.
  local i task_id
  for i in 1 2 3 4 5 6; do
    task_id="$(insert_task done)"
    write_run_fixture "morning-briefing-aaa--slot${i}" "$task_id" "success" 30
    # Stagger mtime by i seconds so item 6 is "newest of the old".
    python3 - "$BRIDGE_STATE_DIR/cron/runs/morning-briefing-aaa--slot${i}" "$i" <<'PY'
import os, sys, time
path = sys.argv[1]
bump = int(sys.argv[2])
ts = int(time.time()) - 30 * 86400 + bump
os.utime(path, (ts, ts))
PY
  done
  local before_runs after_runs
  # shellcheck disable=SC2012  # fixture run_ids are alphanumeric+dash; ls is fine here.
  before_runs="$(ls "$BRIDGE_STATE_DIR/cron/runs" 2>/dev/null | wc -l | tr -d ' ')"
  smoke_assert_eq "6" "$before_runs" "fixture seeded six run dirs"

  local out
  out="$(run_py cleanup-prune --mode run-artifacts \
    --target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB" --json)"
  smoke_assert_contains "$out" '"status": "pruned"' "prune emits pruned status"

  # shellcheck disable=SC2012  # fixture run_ids are alphanumeric+dash; ls is fine here.
  after_runs="$(ls "$BRIDGE_STATE_DIR/cron/runs" 2>/dev/null | wc -l | tr -d ' ')"
  # Floor of 5 → exactly 1 should be deleted.
  smoke_assert_eq "5" "$after_runs" "exactly 1 deleted; 5 kept by always-preserve floor"
}

assert_preserve_floor_keeps_latest_five() {
  # Reset fixtures.
  rm -rf "$BRIDGE_STATE_DIR/cron" "$BRIDGE_SHARED_DIR"/cron-* 2>/dev/null || true
  mkdir -p "$BRIDGE_STATE_DIR/cron/runs" "$BRIDGE_SHARED_DIR/cron-dispatch"

  # 10 entries, all 60 days old (well beyond Tier-A 7d), all "success".
  # Vary mtime by 1s so the sort by mtime DESC is deterministic.
  local i task_id
  for i in $(seq 1 10); do
    task_id="$(insert_task done)"
    write_run_fixture "morning-briefing-floor--slot${i}" "$task_id" "success" 60
    # Bump the mtime forward by i seconds so item 10 is "newest of the old".
    python3 - "$BRIDGE_STATE_DIR/cron/runs/morning-briefing-floor--slot${i}" "$i" <<'PY'
import os, sys, time
path = sys.argv[1]
bump = int(sys.argv[2])
ts = int(time.time()) - 60 * 86400 + bump
os.utime(path, (ts, ts))
PY
  done

  local out
  out="$(run_py cleanup-report --mode run-artifacts \
    --target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB" --json)"
  # By-surface eligibility on state/cron/runs should be 5 (10 - floor of 5).
  python3 - "$out" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
by_surface = payload["summary"]["by_surface"]
got = by_surface.get("state/cron/runs", 0)
expected = 5  # 10 entries - floor of 5
assert got == expected, f"runs eligible: expected {expected}, got {got}; payload={payload}"
preserved = sum(
    1 for r in payload["records"]
    if r["surface"] == "state/cron/runs" and r["skip_reason"] == "preserve_floor"
)
assert preserved == 5, f"expected 5 preserve_floor entries, got {preserved}"
PY
}

assert_skipped_when_queue_status_claimed() {
  rm -rf "$BRIDGE_STATE_DIR/cron" "$BRIDGE_SHARED_DIR"/cron-* 2>/dev/null || true
  mkdir -p "$BRIDGE_STATE_DIR/cron/runs"
  local task_id
  task_id="$(insert_task claimed)"
  write_run_fixture "morning-briefing-claim--slot1" "$task_id" "success" 30
  local out
  out="$(run_py cleanup-report --mode run-artifacts \
    --target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB" --json)"
  python3 - "$out" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
records = payload["records"]
runs_record = next(r for r in records if r["surface"] == "state/cron/runs")
assert runs_record["eligible"] is False, runs_record
assert runs_record["skip_reason"] == "queue_status:claimed", runs_record
PY
}

assert_failed_run_kept_on_tier_a() {
  # state="error" runs should fall back to the Tier-B clock (30d).
  # A 14-day-old failed run on a Tier-A surface (state/cron/runs) is
  # within the Tier-B retention window so it must be preserved.
  rm -rf "$BRIDGE_STATE_DIR/cron" "$BRIDGE_SHARED_DIR"/cron-* 2>/dev/null || true
  local task_id
  task_id="$(insert_task done)"
  write_run_fixture "morning-briefing-err--slot1" "$task_id" "error" 14
  local out
  out="$(run_py cleanup-report --mode run-artifacts \
    --target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB" --json)"
  python3 - "$out" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
records = payload["records"]
runs_record = next(r for r in records if r["surface"] == "state/cron/runs")
assert runs_record["eligible"] is False, runs_record
assert runs_record["skip_reason"] == "within_retention", runs_record
PY
}

assert_skipped_when_live_pid_anchored_under_target_root() {
  rm -rf "$BRIDGE_STATE_DIR/cron" "$BRIDGE_SHARED_DIR"/cron-* 2>/dev/null || true
  local task_id
  task_id="$(insert_task done)"
  local run_id="morning-briefing-pid--slot1"
  # Spawn a long-running process whose argv contains a path rooted at
  # `$BRIDGE_STATE_DIR/cron/...<run_id>...`. We use `bash -c` so the
  # rooted path lands in argv[2] without confusing `sleep`'s arg parser.
  local rooted_path="$BRIDGE_STATE_DIR/cron/runs/$run_id/sentinel"
  bash -c "exec -a 'agb-smoke-live-pid $rooted_path' sleep 30" 2>/dev/null &
  local sleep_pid=$!
  SPAWNED_PIDS+=("$sleep_pid")
  sleep 0.2

  # Seed the run fixture AFTER the sleep launches so the dir mtime is
  # not reset by the sleep argv setup. days_old=30 is well past Tier-A 7d
  # so without the live-PID gate the entry would be eligible for prune.
  write_run_fixture "$run_id" "$task_id" "success" 30

  local out
  out="$(run_py cleanup-report --mode run-artifacts \
    --target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB" --json)"
  kill "$sleep_pid" 2>/dev/null || true
  wait "$sleep_pid" 2>/dev/null || true
  python3 - "$out" "$run_id" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
target_run_id = sys.argv[2]
runs_record = next(
    r for r in payload["records"]
    if r["surface"] == "state/cron/runs" and r["run_id"] == target_run_id
)
assert runs_record["eligible"] is False, runs_record
assert runs_record["skip_reason"] == "live_pid", runs_record
PY
}

assert_foreign_install_pid_does_not_match() {
  # Same run_id appears in argv but rooted under a *different* prefix —
  # the path-anchored matcher must NOT skip our cleanup.
  rm -rf "$BRIDGE_STATE_DIR/cron" "$BRIDGE_SHARED_DIR"/cron-* 2>/dev/null || true
  local task_id
  task_id="$(insert_task done)"
  write_run_fixture "morning-briefing-foreign--slot1" "$task_id" "success" 30
  # Pad the family floor so the test entry isn't preserve_floor-pinned.
  seed_floor_padding "morning-briefing-foreign-padding"

  local foreign_root="$SMOKE_TMP_ROOT/foreign-install"
  mkdir -p "$foreign_root/state/cron/runs/morning-briefing-foreign--slot1"
  local foreign_path="$foreign_root/state/cron/runs/morning-briefing-foreign--slot1/marker"
  bash -c "exec -a 'agb-smoke-foreign-pid $foreign_path' sleep 30" 2>/dev/null &
  local sleep_pid=$!
  SPAWNED_PIDS+=("$sleep_pid")
  sleep 0.2

  local out
  out="$(run_py cleanup-report --mode run-artifacts \
    --target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB" --json)"
  kill "$sleep_pid" 2>/dev/null || true
  wait "$sleep_pid" 2>/dev/null || true
  python3 - "$out" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
runs_record = next(
    r for r in payload["records"]
    if r["surface"] == "state/cron/runs"
    and r["run_id"] == "morning-briefing-foreign--slot1"
)
assert runs_record["eligible"] is True, (
    f"foreign-install PID should not block cleanup; got record={runs_record}"
)
PY
}

assert_symlink_safety() {
  rm -rf "$BRIDGE_STATE_DIR/cron" "$BRIDGE_SHARED_DIR"/cron-* 2>/dev/null || true
  mkdir -p "$BRIDGE_STATE_DIR/cron/runs" "$BRIDGE_SHARED_DIR/cron-dispatch"
  # Create a passwd-like decoy file we never want clobbered.
  local decoy="$SMOKE_TMP_ROOT/decoy-passwd"
  printf 'root:x:0:0:do-not-delete:/root:/bin/bash\n' >"$decoy"

  # Replace one cron-dispatch entry with a symlink to the decoy.
  local symlink_path="$BRIDGE_SHARED_DIR/cron-dispatch/morning-briefing-link--slot1.md"
  ln -s "$decoy" "$symlink_path"

  # Pair it with a legit eligible run so prune actually has work to do.
  local task_id
  task_id="$(insert_task done)"
  write_run_fixture "morning-briefing-real--slot1" "$task_id" "success" 30
  seed_floor_padding "morning-briefing-real-padding"

  local out
  out="$(run_py cleanup-prune --mode run-artifacts \
    --target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB" --json)"
  smoke_assert_contains "$out" '"status": "pruned"' "prune ran on real entry"
  smoke_assert_file_exists "$decoy" "decoy preserved (symlink not followed)"
  local decoy_content
  decoy_content="$(cat "$decoy")"
  smoke_assert_contains "$decoy_content" "do-not-delete" "decoy content intact"
}

assert_dry_run_does_not_mutate() {
  rm -rf "$BRIDGE_STATE_DIR/cron" "$BRIDGE_SHARED_DIR"/cron-* 2>/dev/null || true
  local task_id
  task_id="$(insert_task done)"
  write_run_fixture "morning-briefing-dry--slot1" "$task_id" "success" 30
  seed_floor_padding "morning-briefing-dry-padding"
  local before_count
  # shellcheck disable=SC2012  # fixture run_ids are alphanumeric+dash.
  before_count="$(ls "$BRIDGE_STATE_DIR/cron/runs" 2>/dev/null | wc -l | tr -d ' ')"

  local out
  out="$(run_py cleanup-prune --mode run-artifacts --dry-run \
    --target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB" --json)"
  smoke_assert_contains "$out" '"status": "dry_run"' "dry-run status echoed"

  local after_count
  # shellcheck disable=SC2012  # fixture run_ids are alphanumeric+dash.
  after_count="$(ls "$BRIDGE_STATE_DIR/cron/runs" 2>/dev/null | wc -l | tr -d ' ')"
  smoke_assert_eq "$before_count" "$after_count" "dry-run did not delete"
}

assert_one_shot_mode_backwards_compat() {
  rm -rf "$BRIDGE_STATE_DIR/cron" "$BRIDGE_SHARED_DIR"/cron-* 2>/dev/null || true
  # Issue #533 contract: legacy `--mode expired-one-shot` and the new
  # alias `--mode one-shot` both must keep rewriting jobs.json. Only
  # the path that ran before #533 is exercised here — we do NOT run the
  # one-shot path against run-artifact fixtures, since those are now
  # the responsibility of `--mode run-artifacts`.
  local jobs_file="$BRIDGE_HOME/cron/jobs.json"
  mkdir -p "$BRIDGE_HOME/cron"
  cat >"$jobs_file" <<'EOF'
{"format":"agent-bridge-cron-v1","jobs":[{"id":"keepme","name":"keepme","agentId":"a","schedule":{"kind":"cron","expr":"0 * * * *","tz":"UTC"},"enabled":true,"deleteAfterRun":false}]}
EOF
  local out_legacy out_alias
  out_legacy="$(run_py cleanup-report \
    --jobs-file "$jobs_file" --mode expired-one-shot --json)"
  smoke_assert_contains "$out_legacy" '"candidate_count": 0' "legacy mode runs without error"

  out_alias="$(run_py cleanup-report \
    --jobs-file "$jobs_file" --mode one-shot --json)"
  smoke_assert_contains "$out_alias" '"candidate_count": 0' "one-shot alias runs without error"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  mkdir -p "$BRIDGE_STATE_DIR/cron/runs" \
           "$BRIDGE_STATE_DIR/cron/workers" \
           "$BRIDGE_STATE_DIR/cron/dispatch" \
           "$BRIDGE_SHARED_DIR/cron-dispatch" \
           "$BRIDGE_SHARED_DIR/cron-result" \
           "$BRIDGE_SHARED_DIR/cron-followup"
  seed_tasks_db
  smoke_run "report --mode run-artifacts works on empty tree" assert_basic_dry_run_report
  smoke_run "eligible runs are deleted by prune" assert_eligible_runs_get_pruned
  smoke_run "preserve floor keeps latest 5 per family" assert_preserve_floor_keeps_latest_five
  smoke_run "skip when queue status is claimed" assert_skipped_when_queue_status_claimed
  smoke_run "failed run kept on Tier-A via Tier-B clock" assert_failed_run_kept_on_tier_a
  smoke_run "skip when live PID anchored under target_root" assert_skipped_when_live_pid_anchored_under_target_root
  smoke_run "foreign-install PID does NOT block cleanup" assert_foreign_install_pid_does_not_match
  smoke_run "symlink safety: never follow a symlink" assert_symlink_safety
  smoke_run "dry-run does not mutate" assert_dry_run_does_not_mutate
  smoke_run "one-shot/expired-one-shot backwards compat" assert_one_shot_mode_backwards_compat
  smoke_log "passed"
}

main "$@"
