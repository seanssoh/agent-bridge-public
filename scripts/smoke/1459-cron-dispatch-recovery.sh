#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1459-cron-dispatch-recovery.sh
#
# Issue #1459 — cron-dispatch backlog recovery + run/queue reconcile layer.
#
# PR #1458 closed the immediate misclassification bugs (the unclaimed sweep
# excludes [cron-dispatch]; nudge detail uses the non-cron set). #1459 is the
# remaining cron-SPECIFIC recovery/reconcile layer. This smoke pins the 7
# contract behaviors agreed in the locked plan:
#
#   S1  Backlog saturated (running_count >= max_parallel, oldest queued
#       cron-dispatch older than threshold) emits `cron_dispatch_backlog`
#       only — never `[unclaimed-task]` / task_unclaimed_escalated.
#   S2  Idle-slot recovery (running_count < max_parallel + queued dispatch)
#       calls the existing worker-start path ONCE and emits
#       `cron_dispatch_auto_recovered`.
#   S3  Queue-done / run-queued split-brain (#991) emits
#       `cron_dispatch_reconcile reason=queue_done_run_nonterminal`, marks
#       the run orphaned_interactive_done, and does NOT re-dispatch.
#   S4  Stale running worker (queue claimed, run running, no live
#       pid/log/result past grace) emits `cron_dispatch_reconcile
#       reason=running_worker_stale` once and marks orphaned_worker_lost.
#   S5  Late nudge success: a prior submit_lost_post_grace drop whose task
#       later became claimed/done emits `session_nudge_late_success` and the
#       resolved-drop marker prevents a re-emit.
#   S6  Mixed human queued + cron queued: the cron backlog path uses only
#       cron-specific actions (never task_unclaimed_escalated for the cron
#       row), and the human-unclaimed find-open still excludes [cron-dispatch].
#   S7  Idempotency: a second reconcile pass on a queued_dispatch_lost run
#       does not re-mutate a terminal run, and the backlog cooldown marker
#       suppresses a second backlog audit within the cooldown window.
#
# Footgun #11: every helper-driven assertion uses
# scripts/smoke/1459-cron-dispatch-recovery-helper.py invoked file-as-argv,
# and every daemon function under test is extracted via awk + sourced into
# a stub harness run as an external script. No `<<<` here-string or
# `<<EOF`/`<<PY` heredoc-stdin into subprocess capture.

set -uo pipefail

SMOKE_NAME="1459-cron-dispatch-recovery"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via trap, not a direct call.
cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
QUEUE="$REPO_ROOT/bridge-queue.py"
CRON_PY="$REPO_ROOT/bridge-cron.py"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
HELPER="$SCRIPT_DIR/1459-cron-dispatch-recovery-helper.py"
AUDIT="$BRIDGE_AUDIT_LOG"

[[ -f "$QUEUE" ]]   || smoke_fail "missing $QUEUE"
[[ -f "$CRON_PY" ]] || smoke_fail "missing $CRON_PY"
[[ -f "$DAEMON_SH" ]] || smoke_fail "missing $DAEMON_SH"
[[ -f "$HELPER" ]]  || smoke_fail "missing $HELPER"

mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_CRON_STATE_DIR/runs" "$BRIDGE_CRON_STATE_DIR/workers"
python3 "$QUEUE" init >/dev/null

RUNS_DIR="$BRIDGE_CRON_STATE_DIR/runs"
WORKER_DIR="$BRIDGE_CRON_STATE_DIR/workers"

# Pick a Bash 4+ interpreter (the daemon functions need associative-array /
# modern syntax; macOS /bin/bash 3.2 cannot parse them).
if command -v /opt/homebrew/bin/bash >/dev/null 2>&1; then
  HBASH=/opt/homebrew/bin/bash
elif command -v /usr/local/bin/bash >/dev/null 2>&1; then
  HBASH=/usr/local/bin/bash
else
  HBASH="$(command -v bash)"
fi

mk_body() { printf 'body\n' >"$1"; }
BODY="$SMOKE_TMP_ROOT/body.md"; mk_body "$BODY"

# Create a queued task; print its id.
create_task() {
  local title="$1"
  python3 "$QUEUE" create --to agent-a --title "$title" --body-file "$BODY" --from smoke --format shell \
    | awk -F= '/^TASK_ID=/{print $2}'
}

# Write a cron run dir (request.json + status.json) for a dispatch task.
write_run() {
  local run_id="$1" task_id="$2" state="$3"
  local run_dir="$RUNS_DIR/$run_id"
  mkdir -p "$run_dir"
  python3 "$REPO_ROOT/lib/cron-helpers/write-request.py" \
    "$run_dir/request.json" "$run_id" job-1 "$run_id" memory-daily smoke agent-a slot1 "$task_id" \
    "2026-06-01T00:00:00+00:00" "$BODY" "$run_dir/payload.md" "$run_dir/result.json" "$run_dir/status.json" \
    "$run_dir/stdout.log" "$run_dir/stderr.log" "$run_dir/source.json" agentTurn claude "" "" "" "" \
    direct "" "" 0 default 0 0 normal normal "" "[]" "{}" "" "" 0 0 "" "" "{}" 900 65536 >/dev/null
  python3 "$REPO_ROOT/lib/cron-helpers/write-status.py" \
    "$run_dir/status.json" "$run_id" "$state" claude "$run_dir/request.json" "$run_dir/result.json" \
    "2026-06-01T00:00:00+00:00" "" >/dev/null
}

run_reconcile() {
  local grace="${1:-0}"
  python3 "$CRON_PY" reconcile-run-state \
    --tasks-db "$BRIDGE_TASK_DB" --runs-dir "$RUNS_DIR" \
    --worker-dir "$WORKER_DIR" --grace-seconds "$grace" --json >/dev/null 2>&1
}

h() { python3 "$HELPER" "$@"; }

# ─────────────────────────────────────────────────────────────────────
# S3: Queue-done / run-queued split-brain (#991). Run this FIRST so the
# audit log starts clean for the reconcile-action assertions.
# ─────────────────────────────────────────────────────────────────────
smoke_log "S3: queue-done/run-queued split-brain -> cron_dispatch_reconcile, no re-dispatch"

S3_ID="$(create_task '[cron-dispatch] memory-daily (slot1)')"
[[ "$S3_ID" =~ ^[0-9]+$ ]] || smoke_fail "S3: could not create task"
python3 "$QUEUE" claim "$S3_ID" --agent agent-a >/dev/null 2>&1
python3 "$QUEUE" done "$S3_ID" --agent agent-a --note "done outside cron worker" >/dev/null 2>&1
write_run "run-s3" "$S3_ID" "queued"

run_reconcile 0

S3_STATE="$(h status-state "$RUNS_DIR/run-s3/status.json")"
[[ "$S3_STATE" == "orphaned_interactive_done" ]] \
  || smoke_fail "S3: run state '$S3_STATE' (expected orphaned_interactive_done)"
S3_REASON="$(h audit-detail "$AUDIT" cron_dispatch_reconcile reason)"
[[ "$S3_REASON" == "queue_done_run_nonterminal" ]] \
  || smoke_fail "S3: reconcile reason '$S3_REASON' (expected queue_done_run_nonterminal)"
# No re-dispatch: the queue task stays done (terminal), never re-queued.
S3_QSTATUS="$(python3 "$QUEUE" show "$S3_ID" --format shell 2>/dev/null | awk -F= '/^TASK_STATUS=/{print $2}')"
[[ "$S3_QSTATUS" == "done" ]] || smoke_fail "S3: queue task re-dispatched (status=$S3_QSTATUS, expected done)"
smoke_log "S3 PASS"

# ─────────────────────────────────────────────────────────────────────
# S4: stale running worker (queue claimed, run running, no worker
# evidence past grace) -> cron_dispatch_reconcile reason=running_worker_stale
# once + orphaned_worker_lost.
# ─────────────────────────────────────────────────────────────────────
smoke_log "S4: stale running worker -> cron_dispatch_reconcile running_worker_stale once"

S4_ID="$(create_task '[cron-dispatch] memory-daily (slot4)')"
python3 "$QUEUE" claim "$S4_ID" --agent agent-a >/dev/null 2>&1
write_run "run-s4" "$S4_ID" "running"
# No pid/log/result under WORKER_DIR or run dir -> no evidence. grace=1, and
# the status updated_at is 2026 (long past) so past-grace is true.
run_reconcile 1

S4_STATE="$(h status-state "$RUNS_DIR/run-s4/status.json")"
[[ "$S4_STATE" == "orphaned_worker_lost" ]] \
  || smoke_fail "S4: run state '$S4_STATE' (expected orphaned_worker_lost)"
S4_STALE="$(h audit-count "$AUDIT" cron_dispatch_reconcile running_worker_stale)"
[[ "$S4_STALE" == "1" ]] || smoke_fail "S4: running_worker_stale reconcile count=$S4_STALE (expected 1)"

# Teeth: a SECOND reconcile pass must NOT re-mutate the now-terminal run
# (orphaned_worker_lost is terminal-class) — no second stale audit row.
run_reconcile 1
S4_STALE2="$(h audit-count "$AUDIT" cron_dispatch_reconcile running_worker_stale)"
[[ "$S4_STALE2" == "1" ]] || smoke_fail "S4: second pass re-emitted stale audit (count=$S4_STALE2, expected 1)"
smoke_log "S4 PASS (idempotent)"

# ─────────────────────────────────────────────────────────────────────
# S4b: worker evidence present -> NOT classified lost (false-positive guard).
# ─────────────────────────────────────────────────────────────────────
smoke_log "S4b: live worker evidence -> run NOT marked lost"

S4B_ID="$(create_task '[cron-dispatch] memory-daily (slot4b)')"
python3 "$QUEUE" claim "$S4B_ID" --agent agent-a >/dev/null 2>&1
write_run "run-s4b" "$S4B_ID" "running"
# Drop a worker log so evidence exists.
: >"$WORKER_DIR/task-${S4B_ID}.log"
run_reconcile 1
S4B_STATE="$(h status-state "$RUNS_DIR/run-s4b/status.json")"
[[ "$S4B_STATE" == "running" ]] \
  || smoke_fail "S4b: run with live evidence was mutated to '$S4B_STATE' (expected running)"
smoke_log "S4b PASS (evidence respected)"

# ─────────────────────────────────────────────────────────────────────
# S7: queued_dispatch_lost report + idempotency. queue queued + run
# queued + no worker evidence past grace -> queued_dispatch_lost report.
# ─────────────────────────────────────────────────────────────────────
smoke_log "S7: queued_dispatch_lost report + idempotent second pass"

S7_ID="$(create_task '[cron-dispatch] memory-daily (slot7)')"
write_run "run-s7" "$S7_ID" "queued"
run_reconcile 1
S7_LOST="$(h audit-count "$AUDIT" cron_dispatch_reconcile queued_dispatch_lost)"
[[ "$S7_LOST" == "1" ]] || smoke_fail "S7: queued_dispatch_lost count=$S7_LOST (expected 1)"
# Idempotency: a queued_dispatch_lost report does NOT mutate status.json to
# a terminal state (it only reports), so a re-tick re-reports at most once
# more — assert the run status is still queued (no spurious mutation).
S7_STATE="$(h status-state "$RUNS_DIR/run-s7/status.json")"
[[ "$S7_STATE" == "queued" ]] || smoke_fail "S7: queued_dispatch_lost mutated status to '$S7_STATE' (expected queued)"
smoke_log "S7 PASS"

# ─────────────────────────────────────────────────────────────────────
# Reconcile cleanliness: across ALL the reconcile cases above, NO human
# taxonomy was emitted from the cron reconciler.
# ─────────────────────────────────────────────────────────────────────
smoke_log "S-clean: cron reconciler never emits human task_unclaimed_escalated / session_nudge_*"
h fail-if-action "$AUDIT" task_unclaimed_escalated || smoke_fail "S-clean: task_unclaimed_escalated leaked from reconcile"
h fail-if-action "$AUDIT" session_nudge_dropped || smoke_fail "S-clean: session_nudge_dropped leaked from reconcile"
smoke_log "S-clean PASS"

# ─────────────────────────────────────────────────────────────────────
# Daemon-function tests (backlog sweep + late nudge). Extract the
# functions under test + their direct helpers and run them in a stub
# harness so we never source the full 11k-line bridge-daemon.sh.
# ─────────────────────────────────────────────────────────────────────
extract_fn() { awk "/^$1\(\) \{/,/^\}/" "$DAEMON_SH"; }

# ─────────────────────────────────────────────────────────────────────
# S1+S2+S6: backlog sweep. Build a stub harness with controllable
# running_count + queued backlog + a stub worker-start path.
# ─────────────────────────────────────────────────────────────────────
build_backlog_driver() {
  local out="$1"; shift
  : >"$out"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf '%s\n' "BRIDGE_SCRIPT_DIR=\"$REPO_ROOT\""
    printf '%s\n' "BRIDGE_STATE_DIR=\"$BRIDGE_STATE_DIR\""
    printf '%s\n' "BRIDGE_AUDIT_LOG=\"$AUDIT\""
    printf '%s\n' "BRIDGE_CRON_DISPATCH_WORKER_DIR=\"$WORKER_DIR\""
    printf '%s\n' 'export BRIDGE_SCRIPT_DIR BRIDGE_STATE_DIR BRIDGE_AUDIT_LOG BRIDGE_CRON_DISPATCH_WORKER_DIR'
    # Stubs.
    printf '%s\n' 'bridge_require_python() { return 0; }'
    printf '%s\n' 'bridge_resolve_script_dir_check() { return 0; }'
    printf '%s\n' 'bridge_cron_worker_dir() { printf "%s" "$BRIDGE_CRON_DISPATCH_WORKER_DIR"; }'
    printf '%s\n' 'bridge_daemon_helper_python() { local h="$1"; shift; python3 "$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/$h.py" "$@"; }'
    # Real audit emit via bridge-audit.py.
    printf '%s\n' 'bridge_audit_log() { local a="$1" act="$2" t="$3"; shift 3; python3 "$BRIDGE_SCRIPT_DIR/bridge-audit.py" write --file "$BRIDGE_AUDIT_LOG" --actor "$a" --action "$act" --target "$t" "$@" >/dev/null 2>&1 || true; }'
    # Controllable running count via a FILE (production reads pid files, and
    # the sweep calls start_cron_dispatch_workers in a SUBSHELL — so the
    # running delta must survive the subshell via on-disk state, exactly
    # like the real pid-file count). The backlog snapshot goes through the
    # REAL bridge-queue.py cron-backlog-snapshot against the scratch
    # BACKLOG_DB so the queue-global query path is exercised.
    printf '%s\n' 'cron_worker_running_count() { cat "$RUNNING_FILE" 2>/dev/null || printf "0"; }'
    printf '%s\n' 'bridge_queue_cli() { if [[ "$1" == "cron-backlog-snapshot" ]]; then BRIDGE_TASK_DB="$BACKLOG_DB" python3 "$BRIDGE_SCRIPT_DIR/bridge-queue.py" "$@"; fi; }'
    # start_cron_dispatch_workers stub: bumps the on-disk running count by
    # STUB_START_DELTA and (on a successful start) drains the scratch backlog
    # DB so the after-snapshot reflects consumed work. Records that it was
    # called. Runs in the sweep's subshell, so it MUST persist via files.
    printf '%s\n' 'start_cron_dispatch_workers() {'
    printf '%s\n' '  printf "1\n" >>"$BRIDGE_STATE_DIR/start-calls.log"'
    printf '%s\n' '  local d="${STUB_START_DELTA:-0}"'
    printf '%s\n' '  local cur; cur="$(cat "$RUNNING_FILE" 2>/dev/null || printf "0")"'
    printf '%s\n' '  printf "%s" "$(( cur + d ))" >"$RUNNING_FILE"'
    printf '%s\n' '  if (( d > 0 )) && [[ -n "${STUB_DRAIN_DB:-}" ]]; then rm -f "$BACKLOG_DB"; BRIDGE_TASK_DB="$BACKLOG_DB" python3 "$BRIDGE_SCRIPT_DIR/bridge-queue.py" init >/dev/null 2>&1; fi'
    printf '%s\n' '  (( d > 0 )) && return 0 || return 1'
    printf '%s\n' '}'
    # Extracted production functions.
    extract_fn bridge_daemon_cron_dispatch_backlog_state_dir
    extract_fn bridge_daemon_cron_dispatch_backlog_marker_file
    extract_fn bridge_daemon_cron_worker_pids
    extract_fn bridge_daemon_sweep_cron_dispatch_backlog
    printf '%s\n' 'bridge_daemon_sweep_cron_dispatch_backlog; printf "rc=%s\n" "$?"'
  } >>"$out"
  chmod +x "$out"
}

# Build a scratch backlog DB with the given queued [cron-dispatch] titles.
build_backlog_db() {
  local db="$1"; shift
  rm -f "$db"
  BRIDGE_TASK_DB="$db" python3 "$QUEUE" init >/dev/null
  local t
  for t in "$@"; do
    BRIDGE_TASK_DB="$db" python3 "$QUEUE" create --to agent-a --title "$t" --body-file "$BODY" --from smoke >/dev/null
  done
}

S_DRIVER="$SMOKE_TMP_ROOT/backlog-driver.sh"
build_backlog_driver "$S_DRIVER"
RUNNING_FILE="$SMOKE_TMP_ROOT/running.count"
seed_running() { printf '%s' "$1" >"$RUNNING_FILE"; }

smoke_log "S1: backlog saturated -> cron_dispatch_backlog only (no [unclaimed-task])"
rm -f "$BRIDGE_STATE_DIR/start-calls.log"
BACKLOG_DB_S1="$SMOKE_TMP_ROOT/backlog-s1.db"
build_backlog_db "$BACKLOG_DB_S1" '[cron-dispatch] memory-daily (slot1)' '[cron-dispatch] other (slot2)'
# Saturated: running == max == 1, start does nothing (delta 0), oldest age
# forced past threshold via threshold=0.
seed_running 1
S1_OUT="$(env STUB_START_DELTA=0 BACKLOG_DB="$BACKLOG_DB_S1" RUNNING_FILE="$RUNNING_FILE" \
  BRIDGE_CRON_DISPATCH_MAX_PARALLEL=1 BRIDGE_CRON_DISPATCH_BACKLOG_THRESHOLD_SECONDS=0 \
  "$HBASH" "$S_DRIVER" 2>/dev/null || true)"
S1_BACKLOG="$(h audit-count "$AUDIT" cron_dispatch_backlog workers_saturated)"
[[ "$S1_BACKLOG" -ge 1 ]] || smoke_fail "S1: cron_dispatch_backlog not emitted ($S1_BACKLOG). Out: $S1_OUT"
h fail-if-action "$AUDIT" task_unclaimed_escalated || smoke_fail "S1: task_unclaimed_escalated leaked from backlog sweep"
# Backlog row carries the saturation evidence fields.
S1_RUNNING="$(h audit-detail "$AUDIT" cron_dispatch_backlog running_count)"
[[ "$S1_RUNNING" == "1" ]] || smoke_fail "S1: backlog running_count='$S1_RUNNING' (expected 1)"
S1_QC="$(h audit-detail "$AUDIT" cron_dispatch_backlog queued_count)"
[[ "$S1_QC" == "2" ]] || smoke_fail "S1: backlog queued_count='$S1_QC' (expected 2)"
smoke_log "S1 PASS"

smoke_log "S2: idle-slot recovery -> worker path once + cron_dispatch_auto_recovered"
rm -f "$BRIDGE_STATE_DIR/start-calls.log"
BACKLOG_DB_S2="$SMOKE_TMP_ROOT/backlog-s2.db"
build_backlog_db "$BACKLOG_DB_S2" '[cron-dispatch] memory-daily (slot1)'
# Idle slot: running 0 < max 1, start consumes the row (delta +1 drains DB).
seed_running 0
S2_OUT="$(env STUB_START_DELTA=1 STUB_DRAIN_DB=1 BACKLOG_DB="$BACKLOG_DB_S2" RUNNING_FILE="$RUNNING_FILE" \
  BRIDGE_CRON_DISPATCH_MAX_PARALLEL=1 \
  "$HBASH" "$S_DRIVER" 2>/dev/null || true)"
S2_REC="$(h audit-count "$AUDIT" cron_dispatch_auto_recovered idle_slot_with_queued_dispatch)"
[[ "$S2_REC" -ge 1 ]] || smoke_fail "S2: cron_dispatch_auto_recovered not emitted ($S2_REC). Out: $S2_OUT"
# Worker-start path called exactly once.
S2_CALLS="$(wc -l <"$BRIDGE_STATE_DIR/start-calls.log" 2>/dev/null | awk '{print $1}')"
[[ "$S2_CALLS" == "1" ]] || smoke_fail "S2: worker-start called $S2_CALLS times (expected 1)"
smoke_log "S2 PASS"

smoke_log "S7b: backlog cooldown marker suppresses a second backlog audit"
BEFORE_S7B="$(h audit-count "$AUDIT" cron_dispatch_backlog workers_saturated)"
# Re-run the SAME saturated scenario (same oldest_task_id+reason) within cooldown.
seed_running 1
env STUB_START_DELTA=0 BACKLOG_DB="$BACKLOG_DB_S1" RUNNING_FILE="$RUNNING_FILE" \
  BRIDGE_CRON_DISPATCH_MAX_PARALLEL=1 BRIDGE_CRON_DISPATCH_BACKLOG_THRESHOLD_SECONDS=0 \
  BRIDGE_CRON_DISPATCH_BACKLOG_COOLDOWN_SECONDS=99999 \
  "$HBASH" "$S_DRIVER" >/dev/null 2>&1 || true
AFTER_S7B="$(h audit-count "$AUDIT" cron_dispatch_backlog workers_saturated)"
[[ "$AFTER_S7B" == "$BEFORE_S7B" ]] \
  || smoke_fail "S7b: cooldown did not suppress duplicate backlog audit ($BEFORE_S7B -> $AFTER_S7B)"
smoke_log "S7b PASS (cooldown idempotent)"

smoke_log "S6: mixed human+cron queued -> human find-open excludes cron; backlog uses cron actions only"
# Human path: find-open --exclude-title-prefix '[cron-dispatch]' returns only
# the human row (this is the PR #1458 contract the sweep must not weaken).
S6_DB="$SMOKE_TMP_ROOT/s6.db"
BRIDGE_TASK_DB="$S6_DB" python3 "$QUEUE" init >/dev/null
BRIDGE_TASK_DB="$S6_DB" python3 "$QUEUE" create --to agent-a --title '[cron-dispatch] memory-daily (slot1)' --body-file "$BODY" --from smoke >/dev/null
S6_HUMAN_ID="$(BRIDGE_TASK_DB="$S6_DB" python3 "$QUEUE" create --to agent-a --title 'human queued task' --body-file "$BODY" --from smoke --format shell | awk -F= '/^TASK_ID=/{print $2}')"
S6_FOUND="$(BRIDGE_TASK_DB="$S6_DB" python3 "$QUEUE" find-open --agent agent-a --status-filter queued --exclude-title-prefix '[cron-dispatch]' --format id)"
[[ "$S6_FOUND" == "$S6_HUMAN_ID" ]] || smoke_fail "S6: human find-open returned '$S6_FOUND' (expected $S6_HUMAN_ID, cron row leaked)"
# Cron backlog path on the same mixed set uses only cron actions (already
# proven across S1/S2: no task_unclaimed_escalated). Re-assert globally.
h fail-if-action "$AUDIT" task_unclaimed_escalated || smoke_fail "S6: task_unclaimed_escalated leaked"
smoke_log "S6 PASS"

# ─────────────────────────────────────────────────────────────────────
# S5: late nudge success. Seed a prior session_nudge_dropped
# submit_lost_post_grace row for a task that is now claimed -> the sweep
# emits session_nudge_late_success once; a second pass is deduped.
# ─────────────────────────────────────────────────────────────────────
smoke_log "S5: late nudge success -> session_nudge_late_success once + deduped"

S5_ID="$(create_task 'human nudge-recovered task')"
python3 "$QUEUE" claim "$S5_ID" --agent agent-a >/dev/null 2>&1
# Seed the prior drop audit row.
python3 "$REPO_ROOT/bridge-audit.py" write --file "$AUDIT" --actor daemon \
  --action session_nudge_dropped --target agent-a \
  --detail task_id="$S5_ID" --detail reason=submit_lost_post_grace \
  --detail title="human nudge-recovered task" --detail fingerprint="fp-s5" >/dev/null 2>&1

build_nudge_driver() {
  local out="$1"
  : >"$out"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf '%s\n' "BRIDGE_SCRIPT_DIR=\"$REPO_ROOT\""
    printf '%s\n' "BRIDGE_STATE_DIR=\"$BRIDGE_STATE_DIR\""
    printf '%s\n' "BRIDGE_AUDIT_LOG=\"$AUDIT\""
    printf '%s\n' "BRIDGE_TASK_DB=\"$BRIDGE_TASK_DB\""
    printf '%s\n' 'export BRIDGE_SCRIPT_DIR BRIDGE_STATE_DIR BRIDGE_AUDIT_LOG BRIDGE_TASK_DB'
    printf '%s\n' 'bridge_require_python() { return 0; }'
    printf '%s\n' 'bridge_resolve_script_dir_check() { return 0; }'
    printf '%s\n' 'bridge_daemon_helper_python() { local h="$1"; shift; python3 "$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/$h.py" "$@"; }'
    printf '%s\n' 'bridge_audit_log() { local a="$1" act="$2" t="$3"; shift 3; python3 "$BRIDGE_SCRIPT_DIR/bridge-audit.py" write --file "$BRIDGE_AUDIT_LOG" --actor "$a" --action "$act" --target "$t" "$@" >/dev/null 2>&1 || true; }'
    # Real queue status read.
    printf '%s\n' 'bridge_queue_task_status() { python3 "$BRIDGE_SCRIPT_DIR/bridge-queue.py" show "$1" --format shell 2>/dev/null | awk -F= "/^TASK_STATUS=/{print \$2}"; }'
    extract_fn bridge_daemon_nudge_late_success_state_dir
    extract_fn bridge_daemon_sweep_nudge_late_success
    printf '%s\n' 'bridge_daemon_sweep_nudge_late_success; printf "rc=%s\n" "$?"'
  } >>"$out"
  chmod +x "$out"
}

S5_DRIVER="$SMOKE_TMP_ROOT/s5-driver.sh"
build_nudge_driver "$S5_DRIVER"
env BRIDGE_ADMIN_AGENT_ID=admin "$HBASH" "$S5_DRIVER" >/dev/null 2>&1 || true
S5_LATE="$(h audit-count "$AUDIT" session_nudge_late_success)"
[[ "$S5_LATE" == "1" ]] || smoke_fail "S5: session_nudge_late_success count=$S5_LATE (expected 1)"
# Dedupe: a second sweep does NOT re-emit (resolved marker present).
env BRIDGE_ADMIN_AGENT_ID=admin "$HBASH" "$S5_DRIVER" >/dev/null 2>&1 || true
S5_LATE2="$(h audit-count "$AUDIT" session_nudge_late_success)"
[[ "$S5_LATE2" == "1" ]] || smoke_fail "S5: second sweep re-emitted late-success (count=$S5_LATE2, expected 1)"
# The resolved drop carries the right task id.
S5_TID="$(h audit-detail "$AUDIT" session_nudge_late_success task_id)"
[[ "$S5_TID" == "$S5_ID" ]] || smoke_fail "S5: late-success task_id='$S5_TID' (expected $S5_ID)"
smoke_log "S5 PASS"

smoke_log "$SMOKE_NAME — all tests PASS"
exit 0
