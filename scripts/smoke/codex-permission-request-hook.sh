#!/usr/bin/env bash
# scripts/smoke/codex-permission-request-hook.sh — Codex PermissionRequest hook
# smoke (#8945 Track B). The security-sensitive one.
#
# Validates hooks/codex-permission-request.py against its STRICT contract:
# 1. ensure-codex-hooks wires the PermissionRequest event.
# 2. REDACTION: the audit row carries ONLY tool name + agent + a SHA-256
#    context hash; it NEVER contains the raw file path, command argv, or any
#    secret-shaped value from the tool input.
# 3. NO-DEFAULT-SIDE-EFFECT: with auto-queue unset (default) the hook emits
#    NO permissionDecision, creates NO queue task, and the audit row records
#    skip_reason=audit_only_default.
# 4. TEETH: with BRIDGE_CODEX_PERMISSION_AUTO_QUEUE=on AND an admin agent set,
#    the hook DOES create a single [PERMISSION] queue task; its body carries
#    the redacted context hash but NOT the raw path/argv.
# 5. DEDUPE/THROTTLE: a second request for the same (agent,tool) inside the
#    throttle window does NOT create a second task (audit throttled=true).
# 6. THROTTLE EXPIRY: once the window passes a new task is allowed again.
# 7. FAIL-OPEN: no BRIDGE_AGENT_ID → empty envelope, exit 0, no audit.

set -euo pipefail

SMOKE_NAME="codex-permission-request-hook"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
smoke_require_cmd python3

REPO_ROOT="$SMOKE_REPO_ROOT"
PYTHON_BIN="$(command -v python3)"
HOOKS_DIR="$REPO_ROOT/hooks"
HOOK="$HOOKS_DIR/codex-permission-request.py"
TEST_AGENT="codex-perm-smoke"
ADMIN_AGENT="admin-perm-smoke"
AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
mkdir -p "$(dirname "$AUDIT_LOG")"

# A tool input that embeds a raw path + a generic secret-shaped value. None of
# these substrings may appear in the audit row or any queue task body.
RAW_PATH="/Users/operator/private/keys.txt"
RAW_SECRET="TOPSECRETVALUE12345"
EVENT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$RAW_PATH\",\"content\":\"$RAW_SECRET\"}}"

# Run the hook with explicit env (env -u to clear the operator's inherited
# BRIDGE_ADMIN_AGENT_ID; each test re-pins what it needs).
run_perm_hook() {
  # args: <auto_queue_value|""> <admin_value|""> <throttle_seconds|""> <event_json>
  local auto="$1" admin="$2" throttle="$3" event="$4"
  local -a envargs=(
    env -u BRIDGE_ADMIN_AGENT_ID
    BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR"
    BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" BRIDGE_AUDIT_LOG="$AUDIT_LOG"
    BRIDGE_TASK_DB="$BRIDGE_TASK_DB"
    BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
    BRIDGE_AGENT_ID="$TEST_AGENT"
  )
  [[ -n "$auto" ]] && envargs+=("BRIDGE_CODEX_PERMISSION_AUTO_QUEUE=$auto")
  [[ -n "$admin" ]] && envargs+=("BRIDGE_ADMIN_AGENT_ID=$admin")
  [[ -n "$throttle" ]] && envargs+=("BRIDGE_CODEX_PERMISSION_QUEUE_THROTTLE_SECONDS=$throttle")
  printf '%s' "$event" | "${envargs[@]}" python3 "$HOOK"
}

audit_field() {
  # Print a JSON detail field from the LAST audit row.
  python3 -c "import json,sys; rows=[l for l in open('$AUDIT_LOG') if l.strip()]; print(json.loads(rows[-1])['detail'].get('$1',''))"
}

# ---------------------------------------------------------------------------
# Test 1 — ensure-codex-hooks wires PermissionRequest
# ---------------------------------------------------------------------------
smoke_log "1. ensure-codex-hooks wires PermissionRequest"

CODEX_HOOKS_FILE="$SMOKE_TMP_ROOT/codex-hooks.json"
python3 "$REPO_ROOT/bridge-hooks.py" ensure-codex-hooks \
  --bridge-home "$REPO_ROOT" --python-bin "$PYTHON_BIN" \
  --codex-hooks-file "$CODEX_HOOKS_FILE" --format text >/dev/null 2>&1 \
  || smoke_fail "1: ensure-codex-hooks failed"
hooks_content="$(cat "$CODEX_HOOKS_FILE")"
smoke_assert_contains "$hooks_content" '"PermissionRequest"' "1 PermissionRequest event key"
smoke_assert_contains "$hooks_content" "codex-permission-request.py" "1 PermissionRequest wired"

# Initialize the queue DB so the teeth test can actually create a task.
python3 "$REPO_ROOT/bridge-queue.py" init >/dev/null 2>&1 \
  || smoke_fail "1: queue init failed"

# ---------------------------------------------------------------------------
# Test 2 — default (audit-only): no decision, no task, redacted audit row
# ---------------------------------------------------------------------------
smoke_log "2. default audit-only: redacted, no side effect"

: >"$AUDIT_LOG"
out="$(run_perm_hook "" "" "" "$EVENT")"
smoke_assert_contains "$out" '"hookEventName": "PermissionRequest"' "2 envelope event name"
smoke_assert_not_contains "$out" "permissionDecision" "2 NO permissionDecision (audit-only)"

audit_content="$(cat "$AUDIT_LOG")"
smoke_assert_contains "$audit_content" '"action": "codex_permission_request"' "2 audit action"
smoke_assert_contains "$audit_content" "context_sha256" "2 redacted hash anchor present"
smoke_assert_eq "audit_only_default" "$(audit_field skip_reason)" "2 skip_reason audit_only_default"
smoke_assert_eq "False" "$(audit_field task_created)" "2 no task created"
# REDACTION assertions — the raw path + secret must never appear.
smoke_assert_not_contains "$audit_content" "$RAW_PATH" "2 raw path NOT in audit"
smoke_assert_not_contains "$audit_content" "$RAW_SECRET" "2 secret NOT in audit"
# No throttle marker should be written when no task fired.
[[ -f "$BRIDGE_STATE_DIR/agents/$TEST_AGENT/codex-permission-throttle.json" ]] \
  && smoke_fail "2: throttle marker written without a task" || true

# ---------------------------------------------------------------------------
# Test 3 — auto-queue on but no admin → still no task
# ---------------------------------------------------------------------------
smoke_log "3. auto-queue on, no admin → skip"

: >"$AUDIT_LOG"
run_perm_hook "on" "" "" "$EVENT" >/dev/null
smoke_assert_eq "no_admin_agent" "$(audit_field skip_reason)" "3 skip_reason no_admin_agent"
smoke_assert_eq "False" "$(audit_field task_created)" "3 still no task"

# ---------------------------------------------------------------------------
# Test 4 — TEETH: auto-queue on + admin set → exactly one task, redacted body
# ---------------------------------------------------------------------------
smoke_log "4. teeth: enqueue one [PERMISSION] task"

: >"$AUDIT_LOG"
run_perm_hook "on" "$ADMIN_AGENT" "600" "$EVENT" >/dev/null
smoke_assert_eq "True" "$(audit_field task_created)" "4 task created"

# Exactly one [PERMISSION] task addressed to the admin.
task_count="$(python3 -c "
import sqlite3
db='$BRIDGE_TASK_DB'
c=sqlite3.connect(db); c.row_factory=sqlite3.Row
rows=c.execute(\"SELECT title, body_text, body_path FROM tasks WHERE assigned_to=? AND title LIKE '[PERMISSION]%'\", ('$ADMIN_AGENT',)).fetchall()
print(len(rows))
import json
# Stash the body for the redaction assertion below.
body=''
if rows:
    body=rows[0]['body_text'] or ''
    bp=rows[0]['body_path']
    if (not body) and bp:
        try: body=open(bp).read()
        except OSError: body=''
open('$SMOKE_TMP_ROOT/perm-task-body.txt','w').write(body)
")"
smoke_assert_eq "1" "$task_count" "4 exactly one [PERMISSION] task"

task_body="$(cat "$SMOKE_TMP_ROOT/perm-task-body.txt")"
smoke_assert_contains "$task_body" "context_sha256=" "4 task body carries redacted hash"
smoke_assert_not_contains "$task_body" "$RAW_PATH" "4 raw path NOT in task body"
smoke_assert_not_contains "$task_body" "$RAW_SECRET" "4 secret NOT in task body"

# Throttle marker now exists.
smoke_assert_file_exists "$BRIDGE_STATE_DIR/agents/$TEST_AGENT/codex-permission-throttle.json" \
  "4 throttle marker written"

# ---------------------------------------------------------------------------
# Test 5 — DEDUPE: a second request inside the window does NOT create a task
# ---------------------------------------------------------------------------
smoke_log "5. dedupe: second request within window is throttled"

: >"$AUDIT_LOG"
run_perm_hook "on" "$ADMIN_AGENT" "600" "$EVENT" >/dev/null
smoke_assert_eq "throttled" "$(audit_field skip_reason)" "5 skip_reason throttled"
smoke_assert_eq "True" "$(audit_field throttled)" "5 throttled=true"

# Still exactly one task — no spam.
task_count2="$(python3 -c "
import sqlite3
c=sqlite3.connect('$BRIDGE_TASK_DB')
print(c.execute(\"SELECT COUNT(*) FROM tasks WHERE assigned_to=? AND title LIKE '[PERMISSION]%'\", ('$ADMIN_AGENT',)).fetchone()[0])
")"
smoke_assert_eq "1" "$task_count2" "5 no duplicate task (still 1)"

# ---------------------------------------------------------------------------
# Test 6 — THROTTLE EXPIRY: window=1s, age the marker → a new task is allowed
# ---------------------------------------------------------------------------
smoke_log "6. throttle expiry allows a new task"

# Age the throttle marker so the entry is older than a 1s window.
python3 -c "
import json
p='$BRIDGE_STATE_DIR/agents/$TEST_AGENT/codex-permission-throttle.json'
d=json.load(open(p));
for k in d.get('tools', {}): d['tools'][k]=1
open(p,'w').write(json.dumps(d))
"
: >"$AUDIT_LOG"
run_perm_hook "on" "$ADMIN_AGENT" "1" "$EVENT" >/dev/null
smoke_assert_eq "True" "$(audit_field task_created)" "6 task re-created after window"
task_count3="$(python3 -c "
import sqlite3
c=sqlite3.connect('$BRIDGE_TASK_DB')
print(c.execute(\"SELECT COUNT(*) FROM tasks WHERE assigned_to=? AND title LIKE '[PERMISSION]%'\", ('$ADMIN_AGENT',)).fetchone()[0])
")"
smoke_assert_eq "2" "$task_count3" "6 second task created after expiry"

# ---------------------------------------------------------------------------
# Test 7 — FAIL-OPEN: no agent id → empty envelope, exit 0, no audit, no task
# ---------------------------------------------------------------------------
smoke_log "7. fail-open without agent id"

: >"$AUDIT_LOG"
rc=0
out="$(printf '%s' "$EVENT" | env -u BRIDGE_AGENT_ID -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" BRIDGE_CODEX_PERMISSION_AUTO_QUEUE=on \
  python3 "$HOOK")" || rc=$?
smoke_assert_eq "0" "$rc" "7 exit 0 without agent"
smoke_assert_contains "$out" '"hookEventName": "PermissionRequest"' "7 well-formed envelope"
smoke_assert_not_contains "$out" "permissionDecision" "7 still no decision"
[[ -s "$AUDIT_LOG" ]] && smoke_fail "7: expected no audit row without agent id" || true

# ---------------------------------------------------------------------------
# Test 8 — RECURSION GUARD: the guard env (which _create_permission_task
# exports into the queue-create child via os.environ so the child's hooks
# short-circuit) must, when present on entry, make the hook a no-op. This
# pins the child-env recursion contract: re-entry creates NO audit row and
# NO queue task.
# ---------------------------------------------------------------------------
smoke_log "8. recursion guard short-circuits re-entry"

: >"$AUDIT_LOG"
task_before="$(python3 -c "import sqlite3; print(sqlite3.connect('$BRIDGE_TASK_DB').execute(\"SELECT COUNT(*) FROM tasks WHERE assigned_to=? AND title LIKE '[PERMISSION]%'\", ('$ADMIN_AGENT',)).fetchone()[0])")"
rc=0
out="$(printf '%s' "$EVENT" | env -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents" \
  BRIDGE_AGENT_ID="$TEST_AGENT" BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_CODEX_PERMISSION_AUTO_QUEUE=on BRIDGE_CODEX_PERMISSION_QUEUE_THROTTLE_SECONDS=600 \
  BRIDGE_HOOK_CODEX_PERMISSION_ACTIVE=1 \
  python3 "$HOOK")" || rc=$?
smoke_assert_eq "0" "$rc" "8 exit 0 under recursion guard"
smoke_assert_contains "$out" '"hookEventName": "PermissionRequest"' "8 well-formed envelope"
[[ -s "$AUDIT_LOG" ]] && smoke_fail "8: expected no audit row under recursion guard" || true
task_after="$(python3 -c "import sqlite3; print(sqlite3.connect('$BRIDGE_TASK_DB').execute(\"SELECT COUNT(*) FROM tasks WHERE assigned_to=? AND title LIKE '[PERMISSION]%'\", ('$ADMIN_AGENT',)).fetchone()[0])")"
smoke_assert_eq "$task_before" "$task_after" "8 no task created under recursion guard"

# ---------------------------------------------------------------------------
# Test 9 — TOOL_NAME LEAK CLASS (codex Phase-4 BLOCKING): a hostile tool_name
# that smuggles a path + secret must be sanitized to a canonical token BEFORE
# it reaches EITHER the audit row OR the queue task (title + body). The raw
# path/secret must appear in NEITHER. Teeth: reverting the sanitizer (so
# tool_name is persisted verbatim) makes the NEITHER-leaks assertions fail.
# ---------------------------------------------------------------------------
smoke_log "9. tool_name leak class — sanitized in audit AND queue task"

# Use a fresh agent so its (agent,tool) throttle is clean, and an event whose
# *tool_name* (not tool_input) carries the path+secret.
LEAK_AGENT="codex-perm-leak-smoke"
HOSTILE_TOOL="Write $RAW_PATH $RAW_SECRET"
LEAK_EVENT="{\"tool_name\":\"$HOSTILE_TOOL\",\"tool_input\":{}}"
: >"$AUDIT_LOG"
out="$(printf '%s' "$LEAK_EVENT" | env -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents" \
  BRIDGE_AGENT_ID="$LEAK_AGENT" BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_CODEX_PERMISSION_AUTO_QUEUE=on BRIDGE_CODEX_PERMISSION_QUEUE_THROTTLE_SECONDS=600 \
  python3 "$HOOK")"
smoke_assert_contains "$out" '"hookEventName": "PermissionRequest"' "9 envelope event name"

# The audit row must carry only the sanitized token + a redaction marker, and
# NEITHER the raw path NOR the secret.
audit_content="$(cat "$AUDIT_LOG")"
smoke_assert_contains "$audit_content" '"tool": "Write"' "9 audit tool sanitized to canonical token"
smoke_assert_contains "$audit_content" '"tool_name_redacted": true' "9 audit flags redaction"
smoke_assert_contains "$audit_content" "tool_sha256" "9 audit carries raw-name hash anchor"
smoke_assert_not_contains "$audit_content" "$RAW_PATH" "9 path NOT in audit (tool_name)"
smoke_assert_not_contains "$audit_content" "$RAW_SECRET" "9 secret NOT in audit (tool_name)"

# The queued [PERMISSION] task title + body must also be sanitized.
python3 -c "
import sqlite3
c=sqlite3.connect('$BRIDGE_TASK_DB'); c.row_factory=sqlite3.Row
rows=c.execute(\"SELECT title, body_text, body_path FROM tasks WHERE assigned_to=? AND title LIKE '[PERMISSION]%'\", ('$ADMIN_AGENT',)).fetchall()
blob=''
for r in rows:
    blob += (r['title'] or '')
    b = r['body_text'] or ''
    if (not b) and r['body_path']:
        try: b=open(r['body_path']).read()
        except OSError: b=''
    blob += b
open('$SMOKE_TMP_ROOT/leak-task-blob.txt','w').write(blob)
"
leak_blob="$(cat "$SMOKE_TMP_ROOT/leak-task-blob.txt")"
smoke_assert_contains "$leak_blob" "needs approval for Write" "9 task title sanitized to canonical token"
smoke_assert_not_contains "$leak_blob" "$RAW_PATH" "9 path NOT in queue task (title/body)"
smoke_assert_not_contains "$leak_blob" "$RAW_SECRET" "9 secret NOT in queue task (title/body)"

smoke_log "PASS: $SMOKE_NAME"
