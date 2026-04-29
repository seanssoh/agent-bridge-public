#!/usr/bin/env bash
# tests/admin-static-dynamic-boundary/smoke.sh
#
# Regression test for issue #304 — admin static/dynamic boundary.
# Verifies (portable, runs on macOS with bash 4+):
#
#   1. `agent-bridge agent compact <static>` enqueues a synthetic
#      [admin-compact] task to the static agent and writes an
#      `admin_compact_invoked` audit row.
#   2. `agent-bridge agent compact <dynamic>` rejects with a non-zero
#      exit code and a stderr message identifying the agent as
#      operator-managed. No task is enqueued.
#   3. `agent-bridge agent handoff <static>` enqueues a synthetic
#      [admin-handoff] task. Body references the bridge-spec
#      <agent-home>/NEXT-SESSION.md filename so the receiving agent
#      writes the handoff at the path SessionStart hook auto-consumes.
#
# This test stands up an isolated BRIDGE_HOME under mktemp, never
# touches the live bridge state, and does not require a running tmux
# session or the Claude/Codex CLI.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log() { printf '[admin-boundary] %s\n' "$*"; }
die() { printf '[admin-boundary][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[admin-boundary][skip] %s\n' "$*"; exit 0; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required (have ${BASH_VERSION})"
fi
command -v python3 >/dev/null 2>&1 || skip "python3 missing"
command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 missing"

TMP_ROOT="$(mktemp -d -t admin-boundary-test.XXXXXX)"
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
mkdir -p "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR"
: > "$BRIDGE_ROSTER_FILE"

ADMIN_AGENT="boundary-admin"
STATIC_AGENT="boundary-static"
DYNAMIC_AGENT="boundary-dynamic"
ADMIN_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
STATIC_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$STATIC_AGENT"
DYNAMIC_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$DYNAMIC_AGENT"
mkdir -p "$ADMIN_WORKDIR" "$STATIC_WORKDIR" "$DYNAMIC_WORKDIR"

cat > "$BRIDGE_ROSTER_LOCAL_FILE" <<ROSTER
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_AGENT_IDS=("$ADMIN_AGENT" "$STATIC_AGENT" "$DYNAMIC_AGENT")
BRIDGE_AGENT_DESC[$ADMIN_AGENT]="admin"
BRIDGE_AGENT_DESC[$STATIC_AGENT]="static fixture"
BRIDGE_AGENT_DESC[$DYNAMIC_AGENT]="dynamic fixture"
BRIDGE_AGENT_ENGINE[$ADMIN_AGENT]=claude
BRIDGE_AGENT_ENGINE[$STATIC_AGENT]=claude
BRIDGE_AGENT_ENGINE[$DYNAMIC_AGENT]=claude
BRIDGE_AGENT_SESSION[$ADMIN_AGENT]=$ADMIN_AGENT
BRIDGE_AGENT_SESSION[$STATIC_AGENT]=$STATIC_AGENT
BRIDGE_AGENT_SESSION[$DYNAMIC_AGENT]=$DYNAMIC_AGENT
BRIDGE_AGENT_WORKDIR[$ADMIN_AGENT]=$ADMIN_WORKDIR
BRIDGE_AGENT_WORKDIR[$STATIC_AGENT]=$STATIC_WORKDIR
BRIDGE_AGENT_WORKDIR[$DYNAMIC_AGENT]=$DYNAMIC_WORKDIR
BRIDGE_AGENT_LAUNCH_CMD[$ADMIN_AGENT]=$(printf '%q' "claude")
BRIDGE_AGENT_LAUNCH_CMD[$STATIC_AGENT]=$(printf '%q' "claude")
BRIDGE_AGENT_LAUNCH_CMD[$DYNAMIC_AGENT]=$(printf '%q' "claude")
BRIDGE_AGENT_SOURCE[$ADMIN_AGENT]=static
BRIDGE_AGENT_SOURCE[$STATIC_AGENT]=static
BRIDGE_AGENT_SOURCE[$DYNAMIC_AGENT]=dynamic
BRIDGE_AGENT_ISOLATION_MODE[$ADMIN_AGENT]=shared
BRIDGE_AGENT_ISOLATION_MODE[$STATIC_AGENT]=shared
BRIDGE_AGENT_ISOLATION_MODE[$DYNAMIC_AGENT]=shared
BRIDGE_ADMIN_AGENT_ID=$ADMIN_AGENT
ROSTER

# Tasks DB needs the schema initialized for bridge-task.sh create. The
# easiest portable path is a no-op `inbox` against the empty DB; the
# Python backend creates the schema lazily on first open.
log "initializing tasks.db via empty inbox query"
"$REPO_ROOT/agent-bridge" inbox "$STATIC_AGENT" >/dev/null 2>&1 || true
[[ -f "$BRIDGE_TASK_DB" ]] || die "tasks.db not initialized at $BRIDGE_TASK_DB"

count_tasks_for() {
  local target="$1"
  sqlite3 "$BRIDGE_TASK_DB" \
    "SELECT COUNT(*) FROM tasks WHERE assigned_to='$target'" \
    2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Step 1: agent compact <static> succeeds, enqueues task, writes audit row
# ---------------------------------------------------------------------------

log "step 1 — agent compact <static> on the static fixture"
before_static="$(count_tasks_for "$STATIC_AGENT")"
compact_output="$("$REPO_ROOT/agent-bridge" agent compact "$STATIC_AGENT" 2>&1)" \
  || die "agent compact <static> failed unexpectedly: $compact_output"
echo "$compact_output" | grep -q "kind: compact" \
  || die "agent compact output missing 'kind: compact': $compact_output"
echo "$compact_output" | grep -q "audit_action: admin_compact_invoked" \
  || die "agent compact output missing audit_action: $compact_output"
after_static="$(count_tasks_for "$STATIC_AGENT")"
[[ "$after_static" -eq $((before_static + 1)) ]] \
  || die "expected static inbox to grow by 1, before=$before_static after=$after_static"

log "step 1 — verifying [admin-compact] task body"
compact_body="$(sqlite3 "$BRIDGE_TASK_DB" \
  "SELECT body_text FROM tasks WHERE assigned_to='$STATIC_AGENT' AND title LIKE '[admin-compact]%' ORDER BY id DESC LIMIT 1")"
[[ -n "$compact_body" ]] || die "[admin-compact] task body empty"
echo "$compact_body" | grep -q "NEXT-SESSION.md" \
  || die "[admin-compact] body missing NEXT-SESSION.md filename contract"
echo "$compact_body" | grep -q "Track B" \
  || die "[admin-compact] body missing issue #304 Track B reference"

log "step 1 — verifying admin_compact_invoked audit row"
[[ -f "$BRIDGE_AUDIT_LOG" ]] || die "audit log missing at $BRIDGE_AUDIT_LOG"
grep -Fq '"action": "admin_compact_invoked"' "$BRIDGE_AUDIT_LOG" \
  || die "audit log missing admin_compact_invoked entry"
grep -Fq "\"target\": \"$STATIC_AGENT\"" "$BRIDGE_AUDIT_LOG" \
  || die "audit log missing target=$STATIC_AGENT"

# ---------------------------------------------------------------------------
# Step 2: agent compact <dynamic> rejects, no task enqueued
# ---------------------------------------------------------------------------

log "step 2 — agent compact <dynamic> must reject with non-zero exit"
before_dynamic="$(count_tasks_for "$DYNAMIC_AGENT")"
set +e
reject_output="$("$REPO_ROOT/agent-bridge" agent compact "$DYNAMIC_AGENT" 2>&1)"
reject_status=$?
set -e
[[ "$reject_status" -ne 0 ]] \
  || die "agent compact <dynamic> exited 0; expected non-zero. output: $reject_output"
echo "$reject_output" | grep -q "operator-managed" \
  || die "rejection message missing 'operator-managed': $reject_output"
echo "$reject_output" | grep -q "$DYNAMIC_AGENT" \
  || die "rejection message missing target agent name: $reject_output"
after_dynamic="$(count_tasks_for "$DYNAMIC_AGENT")"
[[ "$after_dynamic" -eq "$before_dynamic" ]] \
  || die "dynamic inbox changed despite rejection: before=$before_dynamic after=$after_dynamic"

# ---------------------------------------------------------------------------
# Step 3: agent handoff <static> enqueues [admin-handoff] task
# ---------------------------------------------------------------------------

log "step 3 — agent handoff <static> on the static fixture"
before_static="$(count_tasks_for "$STATIC_AGENT")"
handoff_output="$("$REPO_ROOT/agent-bridge" agent handoff "$STATIC_AGENT" --note "context critical" 2>&1)" \
  || die "agent handoff <static> failed unexpectedly: $handoff_output"
echo "$handoff_output" | grep -q "kind: handoff" \
  || die "agent handoff output missing 'kind: handoff': $handoff_output"
echo "$handoff_output" | grep -q "audit_action: admin_handoff_invoked" \
  || die "agent handoff output missing audit_action: $handoff_output"
after_static="$(count_tasks_for "$STATIC_AGENT")"
[[ "$after_static" -eq $((before_static + 1)) ]] \
  || die "expected static inbox to grow by 1, before=$before_static after=$after_static"

log "step 3 — verifying [admin-handoff] task body references the bridge-spec NEXT-SESSION.md"
handoff_body="$(sqlite3 "$BRIDGE_TASK_DB" \
  "SELECT body_text FROM tasks WHERE assigned_to='$STATIC_AGENT' AND title LIKE '[admin-handoff]%' ORDER BY id DESC LIMIT 1")"
[[ -n "$handoff_body" ]] || die "[admin-handoff] task body empty"
echo "$handoff_body" | grep -q "<agent-home>/NEXT-SESSION.md" \
  || die "[admin-handoff] body missing <agent-home>/NEXT-SESSION.md spec"
echo "$handoff_body" | grep -q "context critical" \
  || die "[admin-handoff] body missing operator note"

log "step 3 — verifying [admin-handoff-verify] follow-up task landed in admin queue (#304 r2)"
verify_body="$(sqlite3 "$BRIDGE_TASK_DB" \
  "SELECT body_text FROM tasks WHERE assigned_to='$ADMIN_AGENT' AND title LIKE '[admin-handoff-verify]%' ORDER BY id DESC LIMIT 1")"
[[ -n "$verify_body" ]] || die "[admin-handoff-verify] follow-up task not enqueued in admin queue"
echo "$verify_body" | grep -q "NEXT-SESSION.md" \
  || die "[admin-handoff-verify] body missing NEXT-SESSION.md path reference"
echo "$verify_body" | grep -q "admin_handoff_failed" \
  || die "[admin-handoff-verify] body missing admin_handoff_failed audit instruction"

# ---------------------------------------------------------------------------
# Step 3b: agent handoff <dynamic> rejects (#304 r2 — symmetric to step 2)
# ---------------------------------------------------------------------------

log "step 3b — agent handoff <dynamic> must reject with non-zero exit"
set +e
handoff_dyn_output="$("$REPO_ROOT/agent-bridge" agent handoff "$DYNAMIC_AGENT" 2>&1)"
handoff_dyn_rc=$?
set -e
[[ "$handoff_dyn_rc" -ne 0 ]] \
  || die "agent handoff <dynamic> should fail; got rc=0 output=$handoff_dyn_output"
echo "$handoff_dyn_output" | grep -q "dynamic" \
  || die "agent handoff <dynamic> stderr should mention 'dynamic'; got: $handoff_dyn_output"
echo "$handoff_dyn_output" | grep -qi "operator-managed" \
  || die "agent handoff <dynamic> stderr should mention 'operator-managed'; got: $handoff_dyn_output"
no_dyn_handoff_task="$(sqlite3 "$BRIDGE_TASK_DB" \
  "SELECT COUNT(*) FROM tasks WHERE assigned_to='$DYNAMIC_AGENT' AND title LIKE '[admin-handoff]%'")"
[[ "$no_dyn_handoff_task" == "0" ]] \
  || die "agent handoff <dynamic> created a queue task ($no_dyn_handoff_task) — must NOT enqueue when rejected"

log "all steps passed"
