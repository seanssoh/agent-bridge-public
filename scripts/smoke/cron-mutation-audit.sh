#!/usr/bin/env bash
# scripts/smoke/cron-mutation-audit.sh — Issue #628 smoke.
#
# Validates that operator-driven cron CRUD verbs (`create`, `enable`,
# `disable`, `edit`, `delete`) each emit exactly one row to
# `audit.jsonl`. Before #628, none of these mutations recorded
# attribution — operators had to grep agent transcripts to recover
# "who disabled this cron and when." This smoke is the regression
# guard that prevents the audit gap from re-opening.
#
# Each mutation runs against an isolated `BRIDGE_HOME` so no live
# audit log is touched. The smoke also checks that:
#   - `cron.create` carries the agent + title + schedule
#   - `cron.disable` is selected (not `cron.edit`) when only `--disable`
#     flips the enabled flag
#   - `cron.enable` is selected (not `cron.edit`) for the inverse
#   - `cron.edit` is selected when the schedule (or any non-enable
#     field) changes, with prev/next snapshots
#   - `cron.delete` records the deleted job's identity
#   - the actor field reflects `BRIDGE_AGENT_ID` when set

set -euo pipefail

SMOKE_NAME="cron-mutation-audit"
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

# Pin caller agent so we can assert attribution in the audit row.
export BRIDGE_AGENT_ID="smoke-cron-admin"

JOBS_FILE="$BRIDGE_HOME/runtime/cron/jobs.json"
AUDIT_LOG="$BRIDGE_AUDIT_LOG"

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

audit_last() {
  local target="$1"
  local action="$2"
  "$PY_BIN" - "$AUDIT_LOG" "$target" "$action" <<'PY'
import json, sys
log_path, target, action = sys.argv[1], sys.argv[2], sys.argv[3]
last = None
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
            last = row
print(json.dumps(last, ensure_ascii=False, sort_keys=True) if last is not None else "")
PY
}

# ---- 1. create ----------------------------------------------------------
smoke_log "case 1: cron.create emits audit row with agent + schedule"

CREATE_OUT="$("$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-alpha \
  --schedule "0 3 * * *" \
  --tz "Asia/Seoul" \
  --title "memory-daily-agent-alpha")"
JOB_ID="$(printf '%s\n' "$CREATE_OUT" | sed -n 's/^created native cron job \([^ ]*\) for .*$/\1/p')"
[[ -n "$JOB_ID" ]] || smoke_fail "could not parse job id from create output: $CREATE_OUT"

smoke_assert_file_exists "$AUDIT_LOG" "audit log must exist after create"
N_CREATE="$(audit_count "$JOB_ID" "cron.create")"
smoke_assert_eq "1" "$N_CREATE" "expected exactly one cron.create audit row"
ROW="$(audit_last "$JOB_ID" "cron.create")"
"$PY_BIN" - "$ROW" <<'PY'
import json, sys
row = json.loads(sys.argv[1])
assert row["actor"] == "smoke-cron-admin", row
assert row["action"] == "cron.create", row
detail = row.get("detail") or {}
assert detail.get("agent") == "agent-alpha", row
assert detail.get("title") == "memory-daily-agent-alpha", row
schedule = detail.get("schedule") or {}
assert schedule.get("expr") == "0 3 * * *", row
assert detail.get("enabled") is True, row
PY
smoke_log "ok: cron.create row carries actor + agent + schedule"

# ---- 2. disable (toggle-only) -----------------------------------------------
smoke_log "case 2: --disable alone emits cron.disable, not cron.edit"

"$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-update \
  --jobs-file "$JOBS_FILE" \
  --disable \
  "$JOB_ID" >/dev/null

smoke_assert_eq "1" "$(audit_count "$JOB_ID" "cron.disable")" "expected exactly one cron.disable row"
smoke_assert_eq "0" "$(audit_count "$JOB_ID" "cron.edit")" "pure --disable must not record cron.edit"
ROW="$(audit_last "$JOB_ID" "cron.disable")"
"$PY_BIN" - "$ROW" <<'PY'
import json, sys
row = json.loads(sys.argv[1])
detail = row.get("detail") or {}
assert detail.get("prev_enabled") is True, row
assert detail.get("next_enabled") is False, row
PY
smoke_log "ok: cron.disable row records the prev/next enabled flip"

# ---- 3. enable (toggle-only) ------------------------------------------------
smoke_log "case 3: --enable alone emits cron.enable, not cron.edit"

"$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-update \
  --jobs-file "$JOBS_FILE" \
  --enable \
  "$JOB_ID" >/dev/null

smoke_assert_eq "1" "$(audit_count "$JOB_ID" "cron.enable")" "expected exactly one cron.enable row"
smoke_assert_eq "0" "$(audit_count "$JOB_ID" "cron.edit")" "pure --enable must not record cron.edit"
ROW="$(audit_last "$JOB_ID" "cron.enable")"
"$PY_BIN" - "$ROW" <<'PY'
import json, sys
row = json.loads(sys.argv[1])
detail = row.get("detail") or {}
assert detail.get("prev_enabled") is False, row
assert detail.get("next_enabled") is True, row
PY
smoke_log "ok: cron.enable row records the prev/next enabled flip"

# ---- 4. edit (schedule change) ----------------------------------------------
smoke_log "case 4: --schedule change emits cron.edit with prev/next"

"$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-update \
  --jobs-file "$JOBS_FILE" \
  --schedule "30 4 * * *" \
  "$JOB_ID" >/dev/null

smoke_assert_eq "1" "$(audit_count "$JOB_ID" "cron.edit")" "expected exactly one cron.edit row"
ROW="$(audit_last "$JOB_ID" "cron.edit")"
"$PY_BIN" - "$ROW" <<'PY'
import json, sys
row = json.loads(sys.argv[1])
detail = row.get("detail") or {}
prev = detail.get("prev") or {}
nxt = detail.get("next") or {}
assert (prev.get("schedule") or {}).get("expr") == "0 3 * * *", row
assert (nxt.get("schedule") or {}).get("expr") == "30 4 * * *", row
assert prev.get("enabled") is True, row
assert nxt.get("enabled") is True, row
PY
smoke_log "ok: cron.edit row records prev/next schedule snapshots"

# ---- 5. delete --------------------------------------------------------------
smoke_log "case 5: cron.delete emits one row with deleted job identity"

"$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-delete \
  --jobs-file "$JOBS_FILE" \
  "$JOB_ID" >/dev/null

smoke_assert_eq "1" "$(audit_count "$JOB_ID" "cron.delete")" "expected exactly one cron.delete row"
ROW="$(audit_last "$JOB_ID" "cron.delete")"
"$PY_BIN" - "$ROW" <<'PY'
import json, sys
row = json.loads(sys.argv[1])
detail = row.get("detail") or {}
assert detail.get("agent") == "agent-alpha", row
assert detail.get("title") == "memory-daily-agent-alpha", row
schedule = detail.get("schedule") or {}
# After step 4, the schedule should reflect the latest expr "30 4 * * *".
assert schedule.get("expr") == "30 4 * * *", row
PY
smoke_log "ok: cron.delete row carries deleted job identity"

# ---- 6. failed mutation must not emit audit ---------------------------------
smoke_log "case 6: failed delete on missing job must not emit cron.delete"

PRE_DELETE_COUNT="$(audit_count "ghost-job-id" "cron.delete")"
set +e
"$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-delete \
  --jobs-file "$JOBS_FILE" \
  "ghost-job-id" >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || smoke_fail "deleting missing job should fail with non-zero rc"
POST_DELETE_COUNT="$(audit_count "ghost-job-id" "cron.delete")"
smoke_assert_eq "$PRE_DELETE_COUNT" "$POST_DELETE_COUNT" "failed delete must not emit audit row"
smoke_log "ok: failed mutation leaves audit log unchanged"

smoke_log "all cron-mutation-audit cases passed"
