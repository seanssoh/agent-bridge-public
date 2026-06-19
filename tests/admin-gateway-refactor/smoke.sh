#!/usr/bin/env bash
# tests/admin-gateway-refactor/smoke.sh
#
# Issue #345 Track B + C — admin gateway hardcoding refactor.
# Verifies, in an isolated BRIDGE_HOME (mktemp, no live state):
#
#   1. process_crash_reports redirects a non-admin agent's crash to its
#      own notify-target (audit `crash_notified_origin`) and does NOT
#      enqueue a `[crash-loop]` task on admin's queue.
#   2. process_crash_reports falls back to the admin queue when the
#      affected agent has no notify transport (legacy contract preserved
#      so installs without per-agent notify still get a surface).
#   3. bridge_report_channel_health_miss emits a `channel_health_miss`
#      audit row with `dashboard_flag=1` and does NOT enqueue an admin
#      `[channel-health]` task.
#   4. cron-followup classifier — `failure_class=human-config` writes a
#      `cron_human_config_drift` audit row and does NOT create an admin
#      task; `admin-resolvable` (the default) still creates a task once
#      the burst threshold is met.
#   5. process_permission_task_timeout_fanout uses the requesting
#      agent's notify-target as primary when the requester has one,
#      falling back to admin notify otherwise. Audit
#      `permission_fanout` carries `primary=requester` / `primary=admin`.
#   6. bridge-status.py renders a `config-drift (Nd): <count>` line
#      derived from the `cron_human_config_drift` and
#      `channel_health_miss` audit rows.
#
# This test does not require tmux, live Claude/Codex, or the daemon
# main loop. It seeds the minimum pre-state each path expects and
# invokes `bridge-daemon.sh sync` (or the helper directly) once.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log() { printf '[admin-gateway] %s\n' "$*"; }
die() { printf '[admin-gateway][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[admin-gateway][skip] %s\n' "$*"; exit 0; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required (have ${BASH_VERSION})"
fi
command -v python3 >/dev/null 2>&1 || skip "python3 missing"
command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 missing"

TMP_ROOT="$(mktemp -d -t admin-gateway-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT

export BRIDGE_HOME="$TMP_ROOT/bridge-home"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
export BRIDGE_AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
# Pin cron state dir under the temp BRIDGE_HOME so a parent shell that
# inherited the live install's BRIDGE_CRON_STATE_DIR cannot leak in.
export BRIDGE_CRON_STATE_DIR="$BRIDGE_STATE_DIR/cron"
export BRIDGE_DAEMON_NOTIFY_DRY_RUN=1
# Disable noisy / slow subsystems irrelevant to this smoke.
export BRIDGE_SKIP_PLUGIN_LIVENESS=1
mkdir -p "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR"
: > "$BRIDGE_ROSTER_FILE"

ADMIN_AGENT="gateway-admin"
NOTIFY_AGENT="gateway-notify"
SILENT_AGENT="gateway-silent"
REQUESTER_AGENT="gateway-requester"
ADMIN_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
NOTIFY_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$NOTIFY_AGENT"
SILENT_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$SILENT_AGENT"
REQUESTER_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$REQUESTER_AGENT"
mkdir -p "$ADMIN_WORKDIR" "$NOTIFY_WORKDIR" "$SILENT_WORKDIR" "$REQUESTER_WORKDIR"

# Roster fixture:
#   - admin: has notify transport (discord)
#   - notify: has notify transport (discord, distinct channel)
#   - silent: no notify transport (forces admin-fallback paths)
#   - requester: has notify transport (telegram) — used for
#                permission-fanout primary path
cat > "$BRIDGE_ROSTER_LOCAL_FILE" <<ROSTER
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_AGENT_IDS=("$ADMIN_AGENT" "$NOTIFY_AGENT" "$SILENT_AGENT" "$REQUESTER_AGENT")
BRIDGE_AGENT_DESC[$ADMIN_AGENT]="admin"
BRIDGE_AGENT_DESC[$NOTIFY_AGENT]="agent with notify"
BRIDGE_AGENT_DESC[$SILENT_AGENT]="agent without notify"
BRIDGE_AGENT_DESC[$REQUESTER_AGENT]="permission requester"
BRIDGE_AGENT_ENGINE[$ADMIN_AGENT]=claude
BRIDGE_AGENT_ENGINE[$NOTIFY_AGENT]=claude
BRIDGE_AGENT_ENGINE[$SILENT_AGENT]=claude
BRIDGE_AGENT_ENGINE[$REQUESTER_AGENT]=claude
BRIDGE_AGENT_SESSION[$ADMIN_AGENT]=$ADMIN_AGENT
BRIDGE_AGENT_SESSION[$NOTIFY_AGENT]=$NOTIFY_AGENT
BRIDGE_AGENT_SESSION[$SILENT_AGENT]=$SILENT_AGENT
BRIDGE_AGENT_SESSION[$REQUESTER_AGENT]=$REQUESTER_AGENT
BRIDGE_AGENT_WORKDIR[$ADMIN_AGENT]=$ADMIN_WORKDIR
BRIDGE_AGENT_WORKDIR[$NOTIFY_AGENT]=$NOTIFY_WORKDIR
BRIDGE_AGENT_WORKDIR[$SILENT_AGENT]=$SILENT_WORKDIR
BRIDGE_AGENT_WORKDIR[$REQUESTER_AGENT]=$REQUESTER_WORKDIR
BRIDGE_AGENT_LAUNCH_CMD[$ADMIN_AGENT]=\$(printf '%q' "claude")
BRIDGE_AGENT_LAUNCH_CMD[$NOTIFY_AGENT]=\$(printf '%q' "claude")
BRIDGE_AGENT_LAUNCH_CMD[$SILENT_AGENT]=\$(printf '%q' "claude")
BRIDGE_AGENT_LAUNCH_CMD[$REQUESTER_AGENT]=\$(printf '%q' "claude")
BRIDGE_AGENT_SOURCE[$ADMIN_AGENT]=static
BRIDGE_AGENT_SOURCE[$NOTIFY_AGENT]=static
BRIDGE_AGENT_SOURCE[$SILENT_AGENT]=static
BRIDGE_AGENT_SOURCE[$REQUESTER_AGENT]=static
BRIDGE_AGENT_NOTIFY_KIND[$ADMIN_AGENT]=discord
BRIDGE_AGENT_NOTIFY_KIND[$NOTIFY_AGENT]=discord
BRIDGE_AGENT_NOTIFY_KIND[$REQUESTER_AGENT]=telegram
BRIDGE_AGENT_NOTIFY_TARGET[$ADMIN_AGENT]=111111111111111111
BRIDGE_AGENT_NOTIFY_TARGET[$NOTIFY_AGENT]=222222222222222222
BRIDGE_AGENT_NOTIFY_TARGET[$REQUESTER_AGENT]=333333333333333333
BRIDGE_AGENT_NOTIFY_ACCOUNT[$ADMIN_AGENT]=fixture
BRIDGE_AGENT_NOTIFY_ACCOUNT[$NOTIFY_AGENT]=fixture
BRIDGE_AGENT_NOTIFY_ACCOUNT[$REQUESTER_AGENT]=fixture
BRIDGE_ADMIN_AGENT_ID=$ADMIN_AGENT
ROSTER

# Initialize tasks.db schema via an empty inbox query.
log "initializing tasks.db via empty inbox query"
"$REPO_ROOT/agent-bridge" inbox "$ADMIN_AGENT" >/dev/null 2>&1 || true
[[ -f "$BRIDGE_TASK_DB" ]] || die "tasks.db not initialized at $BRIDGE_TASK_DB"

count_open_for_title_prefix() {
  local agent="$1"
  local prefix="$2"
  sqlite3 "$BRIDGE_TASK_DB" \
    "SELECT COUNT(*) FROM tasks WHERE assigned_to='$agent' AND title LIKE '${prefix}%' AND status IN ('queued','claimed')" \
    2>/dev/null || echo 0
}

audit_count_action() {
  local action="$1"
  if [[ ! -f "$BRIDGE_AUDIT_LOG" ]]; then
    echo 0
    return
  fi
  python3 - "$BRIDGE_AUDIT_LOG" "$action" <<'PY'
import json, sys
path, action = sys.argv[1], sys.argv[2]
count = 0
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("action") == action:
            count += 1
print(count)
PY
}

# ---------------------------------------------------------------------------
# Step 1: process_crash_reports redirects to affected agent's notify-target
# ---------------------------------------------------------------------------

log "step 1 — crash report for agent with notify-target redirects to its own surface"

CRASH_ERR="$TMP_ROOT/notify-crash.err"
cat >"$CRASH_ERR" <<'EOF'
fatal: token expired
unable to open runtime config
EOF

bash -c "
  set -e
  source '$REPO_ROOT/bridge-lib.sh'
  bridge_load_roster
  bridge_agent_write_crash_report '$NOTIFY_AGENT' 'claude' 5 1 '$CRASH_ERR' 'claude --dangerously-skip-permissions'
" || die "failed to seed crash report for $NOTIFY_AGENT"

before_redirect="$(audit_count_action crash_notified_origin)"
before_admin_alert="$(audit_count_action crash_loop_admin_alert)"
before_admin_task="$(count_open_for_title_prefix "$ADMIN_AGENT" "[crash-loop] $NOTIFY_AGENT ")"

bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null 2>&1 || die "daemon sync failed (notify-agent crash)"

after_redirect="$(audit_count_action crash_notified_origin)"
after_admin_task="$(count_open_for_title_prefix "$ADMIN_AGENT" "[crash-loop] $NOTIFY_AGENT ")"

(( after_redirect > before_redirect )) \
  || die "expected crash_notified_origin audit row to grow (before=$before_redirect after=$after_redirect)"
[[ "$after_admin_task" == "0" ]] \
  || die "admin must NOT receive [crash-loop] task for non-admin notify-agent (count=$after_admin_task)"
[[ "$before_admin_task" == "0" ]] \
  || die "fixture preconditions wrong: admin queue not empty before sync"

# ---------------------------------------------------------------------------
# Step 2: process_crash_reports falls back to admin queue for silent agent
# ---------------------------------------------------------------------------

log "step 2 — crash report for agent without notify falls back to admin queue"

bash -c "
  set -e
  source '$REPO_ROOT/bridge-lib.sh'
  bridge_load_roster
  bridge_agent_write_crash_report '$SILENT_AGENT' 'claude' 5 1 '$CRASH_ERR' 'claude --dangerously-skip-permissions'
" || die "failed to seed crash report for $SILENT_AGENT"

before_silent_admin_task="$(count_open_for_title_prefix "$ADMIN_AGENT" "[crash-loop] $SILENT_AGENT ")"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null 2>&1 || die "daemon sync failed (silent-agent crash)"
after_silent_admin_task="$(count_open_for_title_prefix "$ADMIN_AGENT" "[crash-loop] $SILENT_AGENT ")"

(( after_silent_admin_task > before_silent_admin_task )) \
  || die "expected admin queue to receive [crash-loop] for silent agent (before=$before_silent_admin_task after=$after_silent_admin_task)"

# ---------------------------------------------------------------------------
# Step 3: bridge_report_channel_health_miss emits audit + dashboard flag,
#         does not create admin task
# ---------------------------------------------------------------------------

log "step 3 — channel-health miss surfaces via audit + dashboard flag (no admin task)"

CHANNEL_HEALTH_AGENT="gateway-broken-channel"
CHANNEL_HEALTH_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$CHANNEL_HEALTH_AGENT"
mkdir -p "$CHANNEL_HEALTH_WORKDIR"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<ROSTER

bridge_add_agent_id_if_missing "$CHANNEL_HEALTH_AGENT"
BRIDGE_AGENT_DESC["$CHANNEL_HEALTH_AGENT"]="Broken channel role"
BRIDGE_AGENT_ENGINE["$CHANNEL_HEALTH_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$CHANNEL_HEALTH_AGENT"]="$CHANNEL_HEALTH_AGENT"
BRIDGE_AGENT_WORKDIR["$CHANNEL_HEALTH_AGENT"]="$CHANNEL_HEALTH_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$CHANNEL_HEALTH_AGENT"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CHANNELS["$CHANNEL_HEALTH_AGENT"]="plugin:discord"
ROSTER

before_health_miss="$(audit_count_action channel_health_miss)"
before_health_task="$(count_open_for_title_prefix "$ADMIN_AGENT" "[channel-health] $CHANNEL_HEALTH_AGENT ")"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null 2>&1 || die "daemon sync failed (channel-health)"
after_health_miss="$(audit_count_action channel_health_miss)"
after_health_task="$(count_open_for_title_prefix "$ADMIN_AGENT" "[channel-health] $CHANNEL_HEALTH_AGENT ")"

(( after_health_miss > before_health_miss )) \
  || die "expected channel_health_miss audit row to grow (before=$before_health_miss after=$after_health_miss)"
[[ "$after_health_task" == "0" ]] \
  || die "admin must NOT receive [channel-health] task (count=$after_health_task)"
[[ "$before_health_task" == "0" ]] \
  || die "fixture preconditions wrong: admin queue had channel-health task before sync"

python3 - "$BRIDGE_AUDIT_LOG" "$CHANNEL_HEALTH_AGENT" <<'PY' || die "channel_health_miss audit row missing dashboard_flag=1"
import json, sys
path, agent = sys.argv[1], sys.argv[2]
found = False
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("action") != "channel_health_miss":
            continue
        if row.get("target") != agent:
            continue
        detail = row.get("detail") or {}
        if str(detail.get("dashboard_flag")) == "1":
            found = True
            break
if not found:
    sys.exit(1)
PY

# ---------------------------------------------------------------------------
# Step 4: cron-followup classifier — human-config vs admin-resolvable
# ---------------------------------------------------------------------------

log "step 4 — cron-followup human-config drift writes audit, no admin task"

# Helper: stage a cron-dispatch task with a chosen failure_class and run
# the cron worker once. Mirrors the smoke pattern used by the existing
# scripts/smoke-test.sh cron block.
stage_and_run_cron_followup() {
  local run_id="$1"
  local failure_class="$2"
  local job_name="$3"
  local target_agent="$4"
  local run_dir="$BRIDGE_STATE_DIR/cron/runs/$run_id"
  local request_file="$run_dir/request.json"
  local result_file="$run_dir/result.json"
  local status_file="$run_dir/status.json"
  local prompt_file="$run_dir/prompt.txt"
  # Dispatch body filename is `<run_id>.md` so that
  # `bridge_cron_run_id_from_body_path` recovers the correct run_id from
  # the queue task's body_path. Mirrors scripts/smoke-test.sh:7801.
  local dispatch_body="$BRIDGE_SHARED_DIR/cron-dispatch/$run_id.md"

  mkdir -p "$run_dir" "$(dirname "$dispatch_body")"
  : >"$prompt_file"
  cat >"$request_file" <<EOF
{
  "run_id": "$run_id",
  "job_id": "$job_name",
  "job_name": "$job_name",
  "family": "$job_name",
  "slot": "$run_id",
  "target_agent": "$target_agent",
  "target_engine": "claude",
  "result_file": "$result_file",
  "status_file": "$status_file",
  "request_file": "$request_file",
  "stdout_log": "$run_dir/stdout.log",
  "stderr_log": "$run_dir/stderr.log",
  "failure_class": "$failure_class"
}
EOF
  cat >"$status_file" <<EOF
{
  "run_id": "$run_id",
  "state": "success",
  "engine": "claude",
  "request_file": "$request_file",
  "result_file": "$result_file"
}
EOF
  # Subagent reports an error so cron-followup classifier branch fires.
  cat >"$result_file" <<EOF
{
  "status": "error",
  "summary": "fixture failure ($failure_class)",
  "needs_human_followup": true,
  "failure_class": "$failure_class",
  "recommended_next_steps": ["fixture only"],
  "actions_taken": [],
  "artifacts": [],
  "confidence": "high"
}
EOF
  cat >"$dispatch_body" <<EOF
# [cron-dispatch] $job_name

- run_id: $run_id
- failure_class: $failure_class
EOF
  local create_output
  create_output="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$target_agent" --title "[cron-dispatch] $job_name ($run_id)" --body-file "$dispatch_body" --from gateway-smoke 2>/dev/null)"
  local dispatch_id=""
  [[ "$create_output" =~ created\ task\ \#([0-9]+) ]] && dispatch_id="${BASH_REMATCH[1]}"
  [[ "$dispatch_id" =~ ^[0-9]+$ ]] || die "could not parse cron-dispatch task id ($create_output)"
  bash "$REPO_ROOT/bridge-queue.py" claim "$dispatch_id" --agent "$target_agent" --lease-seconds 900 >/dev/null 2>&1 || true
  bash "$REPO_ROOT/bridge-daemon.sh" run-cron-worker "$dispatch_id" >/dev/null 2>&1 || true
}

# Bump fail-burst threshold to 1 so a single admin-resolvable failure is
# enough to verify task creation in this fixture. Default 3 keeps the
# default smoke quiet on transient errors.
export BRIDGE_CRON_FOLLOWUP_FAIL_BURST_THRESHOLD=1

before_drift="$(audit_count_action cron_human_config_drift)"
before_drift_admin_task="$(count_open_for_title_prefix "$ADMIN_AGENT" "[cron-followup] gateway-drift-job ")"
stage_and_run_cron_followup "gateway-drift-run--2026-04-26" "human-config" "gateway-drift-job" "$ADMIN_AGENT"
after_drift="$(audit_count_action cron_human_config_drift)"
after_drift_admin_task="$(count_open_for_title_prefix "$ADMIN_AGENT" "[cron-followup] gateway-drift-job ")"

(( after_drift > before_drift )) \
  || die "expected cron_human_config_drift audit row to grow (before=$before_drift after=$after_drift)"
[[ "$after_drift_admin_task" == "0" ]] \
  || die "human-config cron-followup must NOT enqueue admin task (count=$after_drift_admin_task)"

log "step 4 — cron-followup admin-resolvable still creates admin task"

before_admin_followup="$(count_open_for_title_prefix "$ADMIN_AGENT" "[cron-followup] gateway-admin-job ")"
stage_and_run_cron_followup "gateway-admin-run--2026-04-26" "admin-resolvable" "gateway-admin-job" "$ADMIN_AGENT"
after_admin_followup="$(count_open_for_title_prefix "$ADMIN_AGENT" "[cron-followup] gateway-admin-job ")"

(( after_admin_followup > before_admin_followup )) \
  || die "admin-resolvable cron-followup must enqueue admin task (before=$before_admin_followup after=$after_admin_followup)"

# ---------------------------------------------------------------------------
# Step 5: PERMISSION fan-out — requester primary, admin fallback
# ---------------------------------------------------------------------------

log "step 5 — PERMISSION fan-out picks requester's notify-target as primary"

# Stage an aged [PERMISSION] task. We can't easily backdate created_ts via
# the public CLI, so we update tasks.created_ts directly via sqlite3.
PERM_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$ADMIN_AGENT" --title "[PERMISSION] $REQUESTER_AGENT needs approval for tool" --body "permission body" --from "$REQUESTER_AGENT" 2>/dev/null)"
[[ "$PERM_CREATE_OUTPUT" =~ created\ task\ \#([0-9]+) ]] || die "could not parse permission task id ($PERM_CREATE_OUTPUT)"
PERM_TASK_ID="${BASH_REMATCH[1]}"
sqlite3 "$BRIDGE_TASK_DB" "UPDATE tasks SET created_ts=strftime('%s','now')-9999 WHERE id=$PERM_TASK_ID;" 2>/dev/null

before_fanout="$(audit_count_action permission_fanout)"
BRIDGE_DAEMON_PERMISSION_TIMEOUT_SECONDS=60 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null 2>&1 || die "daemon sync failed (permission fanout primary path)"
after_fanout="$(audit_count_action permission_fanout)"
(( after_fanout > before_fanout )) \
  || die "expected permission_fanout audit row to grow (before=$before_fanout after=$after_fanout)"

python3 - "$BRIDGE_AUDIT_LOG" "$REQUESTER_AGENT" <<'PY' || die "permission_fanout audit row should mark primary=requester for $REQUESTER_AGENT"
import json, sys
path, agent = sys.argv[1], sys.argv[2]
found = False
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("action") != "permission_fanout":
            continue
        if row.get("target") != agent:
            continue
        if (row.get("detail") or {}).get("primary") == "requester":
            found = True
            break
if not found:
    sys.exit(1)
PY

log "step 5 — PERMISSION fan-out falls back to admin when requester has no notify"

# Re-issue the same fanout for a requester WITHOUT notify (silent agent).
# Need a NEW permission task because the prior one was marker-deduped.
PERM2_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$ADMIN_AGENT" --title "[PERMISSION] $SILENT_AGENT needs approval for tool" --body "permission body 2" --from "$SILENT_AGENT" 2>/dev/null)"
[[ "$PERM2_CREATE_OUTPUT" =~ created\ task\ \#([0-9]+) ]] || die "could not parse second permission task id"
PERM2_TASK_ID="${BASH_REMATCH[1]}"
sqlite3 "$BRIDGE_TASK_DB" "UPDATE tasks SET created_ts=strftime('%s','now')-9999 WHERE id=$PERM2_TASK_ID;" 2>/dev/null

before_admin_primary="$(audit_count_action permission_fanout)"
BRIDGE_DAEMON_PERMISSION_TIMEOUT_SECONDS=60 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null 2>&1 || die "daemon sync failed (permission fanout admin fallback)"
after_admin_primary="$(audit_count_action permission_fanout)"
(( after_admin_primary > before_admin_primary )) \
  || die "expected second permission_fanout audit row (before=$before_admin_primary after=$after_admin_primary)"

python3 - "$BRIDGE_AUDIT_LOG" "$SILENT_AGENT" <<'PY' || die "permission_fanout audit row should mark primary=admin for $SILENT_AGENT"
import json, sys
path, agent = sys.argv[1], sys.argv[2]
found = False
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("action") != "permission_fanout":
            continue
        if row.get("target") != agent:
            continue
        if (row.get("detail") or {}).get("primary") == "admin":
            found = True
            break
if not found:
    sys.exit(1)
PY

# ---------------------------------------------------------------------------
# Step 6: bridge-status.py renders the config-drift line
# ---------------------------------------------------------------------------

log "step 6 — bridge-status.py renders config-drift counter"

ROSTER_SNAPSHOT="$TMP_ROOT/roster-snapshot.tsv"
: > "$ROSTER_SNAPSHOT"
DAEMON_PID_FILE="$BRIDGE_STATE_DIR/daemon.pid"
[[ -f "$DAEMON_PID_FILE" ]] || : > "$DAEMON_PID_FILE"
# The config-drift line is an audit-parse analytic deferred behind `--full`
# (status-fast-default): the default human dashboard skips it, so it only
# renders with `--full`.
STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-status.py" \
  --roster-snapshot "$ROSTER_SNAPSHOT" \
  --db "$BRIDGE_TASK_DB" \
  --daemon-pid-file "$DAEMON_PID_FILE" \
  --audit-log "$BRIDGE_AUDIT_LOG" \
  --config-drift-window-days 7 \
  --full)" \
  || die "bridge-status.py render failed"

expected_drift="$(audit_count_action cron_human_config_drift)"
[[ "$expected_drift" -ge 1 ]] \
  || die "fixture invariant broken: cron_human_config_drift audit count is $expected_drift, expected >=1"
echo "$STATUS_OUTPUT" | grep -Eq "^config-drift \(7d\): ${expected_drift}\$" \
  || die "config-drift counter mismatch: status=\"$(echo "$STATUS_OUTPUT" | grep '^config-drift')\", expected count=${expected_drift}"

log "all steps passed"
