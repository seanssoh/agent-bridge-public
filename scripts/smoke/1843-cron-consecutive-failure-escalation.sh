#!/usr/bin/env bash
# scripts/smoke/1843-cron-consecutive-failure-escalation.sh — Issue #1843
# (secondary footgun) smoke.
#
# Background: the PRIMARY #1843 root cause (iso-targeted text-payload cron
# misclassified as `request_artifact_tampered` on every run) is fixed under
# #1842. This smoke pins the SECONDARY footgun the same incident exposed: a
# recurring cron that fails on EVERY run accumulated `consecutiveErrors`
# silently with NO human escalation, so a customer-facing pipeline was down
# for 7 days (1898 consecutive errors) before anyone noticed.
#
# The fix makes `bridge-cron.py native-finalize-run` trip an escalation when
# back-to-back failures cross a threshold/cadence:
#   - emit a durable `cron_consecutive_failure_escalated` audit row, and
#   - surface an `escalation` block in the finalize JSON payload (so the shell
#     wrapper / a monitoring agent can also notify the owner).
#
# What this smoke asserts (all on an isolated BRIDGE_HOME, no live state):
#   A. Pure boundary unit: `_cron_consecutive_failure_escalation(n)` fires at
#      exactly the threshold and on the re-notify cadence, never below.
#   B. End-to-end native-finalize-run: simulated error runs below the
#      threshold produce NO escalation block and NO audit row; the run that
#      reaches the threshold produces BOTH; a subsequent (non-cadence) error
#      run does NOT re-escalate; a success run resets the counter and clears
#      the `lastEscalatedErrorCount` provenance marker.
#
# Platform note: this exercises the controller-side finalize bookkeeping only.
# It needs NO iso UID, no setfacl, and no group widening, so it runs
# identically on macOS and Linux. The iso/group-write run-dir interaction is
# the #1842 surface (smoke 1842-cron-tamper-iso-groupwrite); the Linux-only
# re-gate for THIS fix (delivery of the escalation to the owning agent over a
# live queue) is documented in the PR, not asserted here.

set -euo pipefail

SMOKE_NAME="1843-cron-consecutive-failure-escalation"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home
export BRIDGE_AGENT_ID="smoke-cron-admin"

AUDIT_LOG="$BRIDGE_AUDIT_LOG"

# --- A. Pure boundary unit on the escalation predicate ----------------------
smoke_log "case A: _cron_consecutive_failure_escalation boundary matrix"
"$PY_BIN" - "$REPO_ROOT" <<'PY'
import importlib.util, sys

repo = sys.argv[1]
spec = importlib.util.spec_from_file_location("bridge_cron", f"{repo}/bridge-cron.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

at = mod.CRON_CONSECUTIVE_FAILURE_ESCALATE_AT
every = mod.CRON_CONSECUTIVE_FAILURE_RENOTIFY_EVERY
fn = mod._cron_consecutive_failure_escalation

# Below threshold: never escalate.
for n in range(0, at):
    assert fn(n) is False, f"n={n} must not escalate (below threshold {at})"

# Exactly at threshold: escalate once.
assert fn(at) is True, f"n={at} must escalate (threshold)"

# Between threshold and the first cadence hit: no re-escalation.
for n in range(at + 1, at + every):
    assert fn(n) is False, f"n={n} must not re-escalate before cadence"

# First cadence hit after threshold: escalate again.
assert fn(at + every) is True, f"n={at + every} must re-escalate (cadence)"
assert fn(at + 2 * every) is True, f"n={at + 2 * every} must re-escalate (cadence)"

# Non-int input degrades to False, never raises.
assert fn(None) is False
assert fn("nope") is False
print("ok")
PY
smoke_log "ok: predicate fires at threshold + on cadence, never below"

# --- B. End-to-end native-finalize-run escalation ---------------------------
smoke_log "case B: native-finalize-run trips escalation at threshold, resets on success"

JOBS_FILE="$BRIDGE_NATIVE_CRON_JOBS_FILE"
mkdir -p "$(dirname "$JOBS_FILE")"

CREATE_OUT="$("$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-alpha \
  --schedule "*/5 * * * *" \
  --tz "Asia/Seoul" \
  --title "intake-poll-agent-alpha")"
JOB_ID="$(printf '%s\n' "$CREATE_OUT" | sed -n 's/^created native cron job \([^ ]*\) for .*$/\1/p')"
[[ -n "$JOB_ID" ]] || smoke_fail "could not parse job id from create output: $CREATE_OUT"

RUN_ROOT="$BRIDGE_CRON_STATE_DIR/runs"
mkdir -p "$RUN_ROOT"

ESC_ACTION="cron_consecutive_failure_escalated"

audit_count() {
  local target="$1"
  local action="$2"
  if [[ ! -f "$AUDIT_LOG" ]]; then
    printf '0\n'
    return
  fi
  "$PY_BIN" - "$AUDIT_LOG" "$target" "$action" <<'PY'
import json, sys
log_path, target, action = sys.argv[1], sys.argv[2], sys.argv[3]
n = 0
with open(log_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("target") == target and row.get("action") == action:
            n += 1
print(n)
PY
}

# Drive one terminal run through native-finalize-run.
#   $1 = run state ("error" | "success")
# Prints the finalize JSON payload on stdout.
finalize_run() {
  local state="$1"
  local run_id
  run_id="run-$(date +%s)-$RANDOM"
  local run_dir="$RUN_ROOT/$run_id"
  mkdir -p "$run_dir"
  local status_file="$run_dir/status.json"
  local result_file="$run_dir/result.json"
  local request_file="$run_dir/request.json"

  if [[ "$state" == "success" ]]; then
    printf '%s\n' '{"state":"success"}' >"$status_file"
    printf '%s\n' '{"status":"ok","summary":"ran"}' >"$result_file"
  else
    printf '%s\n' '{"state":"error","error":"request_artifact_tampered"}' >"$status_file"
    printf '%s\n' '{"status":"error","runner_error":"request_artifact_tampered","summary":"tampered"}' >"$result_file"
  fi

  "$PY_BIN" - "$request_file" "$JOBS_FILE" "$JOB_ID" "$run_id" "$status_file" "$result_file" <<'PY'
import json, sys
req_path, jobs_file, job_id, run_id, status_file, result_file = sys.argv[1:7]
with open(req_path, "w", encoding="utf-8") as fh:
    json.dump({
        "source_file": jobs_file,
        "job_id": job_id,
        "run_id": run_id,
        "status_file": status_file,
        "result_file": result_file,
    }, fh)
PY

  "$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-finalize-run \
    --jobs-file "$JOBS_FILE" \
    --request-file "$request_file" \
    --json
}

THRESHOLD="$("$PY_BIN" - "$REPO_ROOT" <<'PY'
import importlib.util, sys
repo = sys.argv[1]
spec = importlib.util.spec_from_file_location("bridge_cron", f"{repo}/bridge-cron.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.CRON_CONSECUTIVE_FAILURE_ESCALATE_AT)
PY
)"
[[ "$THRESHOLD" -ge 2 ]] || smoke_fail "unexpected threshold: $THRESHOLD"

# Fail (THRESHOLD-1) times: no escalation block, no audit row.
i=1
while [[ $i -lt $THRESHOLD ]]; do
  OUT="$(finalize_run error)"
  smoke_assert_not_contains "$OUT" '"escalation"' "run $i (< threshold) must not carry an escalation block"
  i=$((i + 1))
done
smoke_assert_eq "0" "$(audit_count "$JOB_ID" "$ESC_ACTION")" "no escalation audit row before threshold"
smoke_log "ok: $((THRESHOLD - 1)) sub-threshold failures stayed silent"

# The THRESHOLD-th failure: escalation block + exactly one audit row.
OUT="$(finalize_run error)"
smoke_assert_contains "$OUT" '"escalation"' "threshold failure must carry an escalation block"
smoke_assert_contains "$OUT" '"consecutive_failure"' "escalation kind must be consecutive_failure"
smoke_assert_contains "$OUT" "agent-alpha" "escalation must name the owning agent"
smoke_assert_eq "1" "$(audit_count "$JOB_ID" "$ESC_ACTION")" "exactly one escalation audit row at threshold"
smoke_log "ok: threshold failure tripped escalation block + audit row"

# Assert the escalation payload + audit detail carry the counter + threshold.
"$PY_BIN" - "$OUT" "$THRESHOLD" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
threshold = int(sys.argv[2])
esc = payload.get("escalation") or {}
assert esc.get("kind") == "consecutive_failure", payload
assert esc.get("agent") == "agent-alpha", payload
assert int(esc.get("consecutive_errors")) == threshold, payload
assert int(esc.get("threshold")) == threshold, payload
assert "last_error" in esc, payload
print("ok")
PY

# One more failure just past threshold (not a cadence hit): NO re-escalation.
OUT="$(finalize_run error)"
smoke_assert_not_contains "$OUT" '"escalation"' "post-threshold non-cadence failure must not re-escalate"
smoke_assert_eq "1" "$(audit_count "$JOB_ID" "$ESC_ACTION")" "escalation audit count unchanged off-cadence"
smoke_log "ok: off-cadence post-threshold failure did not spam a second escalation"

# Success run resets the counter and clears the escalation provenance marker.
OUT="$(finalize_run success)"
smoke_assert_contains "$OUT" '"final_status": "success"' "success run must finalize as success"
"$PY_BIN" - "$JOBS_FILE" "$JOB_ID" <<'PY'
import json, sys
jobs_file, job_id = sys.argv[1], sys.argv[2]
with open(jobs_file, "r", encoding="utf-8") as fh:
    payload = json.load(fh)
job = next(j for j in payload["jobs"] if j.get("id") == job_id)
state = job.get("state") or {}
assert int(state.get("consecutiveErrors") or 0) == 0, state
assert "lastEscalatedErrorCount" not in state, state
print("ok")
PY
smoke_log "ok: success reset consecutiveErrors + cleared lastEscalatedErrorCount"

smoke_log "PASS: $SMOKE_NAME"
