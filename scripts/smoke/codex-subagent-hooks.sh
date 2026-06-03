#!/usr/bin/env bash
# scripts/smoke/codex-subagent-hooks.sh — Codex SubagentStart/Stop hook smoke (#8945 Track B).
#
# Validates hooks/codex-subagent-start.py + hooks/codex-subagent-stop.py:
# 1. ensure-codex-hooks wires both SubagentStart + SubagentStop events.
# 2. SubagentStart on a synthetic fan-out event:
#      - emits a well-formed Codex envelope (hookEventName=SubagentStart),
#      - exits 0 (never constrains the fan-out, no decision),
#      - emits an audit row action=subagent_fanout phase=start.
# 3. SubagentStop on a synthetic completion event:
#      - emits a well-formed Codex envelope (hookEventName=SubagentStop),
#      - exits 0,
#      - emits an audit row action=subagent_fanout phase=stop.
# 4. Redaction: a raw prompt / argv field on the event is NOT persisted into
#    the audit row (only the bounded name/id/summary/status are).
# 5. No BRIDGE_AGENT_ID → empty envelope, exit 0, no audit row.

set -euo pipefail

SMOKE_NAME="codex-subagent-hooks"
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
TEST_AGENT="codex-subagent-smoke"
AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
mkdir -p "$(dirname "$AUDIT_LOG")"

run_subagent_hook() {
  local hook_path="$1" event_json="$2"
  printf '%s' "$event_json" | env \
    BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
    BRIDGE_AGENT_ID="$TEST_AGENT" \
    python3 "$hook_path"
}

# ---------------------------------------------------------------------------
# Test 1 — ensure-codex-hooks wires both subagent events
# ---------------------------------------------------------------------------
smoke_log "1. ensure-codex-hooks wires SubagentStart + SubagentStop"

CODEX_HOOKS_FILE="$SMOKE_TMP_ROOT/codex-hooks.json"
python3 "$REPO_ROOT/bridge-hooks.py" ensure-codex-hooks \
  --bridge-home "$REPO_ROOT" --python-bin "$PYTHON_BIN" \
  --codex-hooks-file "$CODEX_HOOKS_FILE" --format text >/dev/null 2>&1 \
  || smoke_fail "1: ensure-codex-hooks failed"
hooks_content="$(cat "$CODEX_HOOKS_FILE")"
smoke_assert_contains "$hooks_content" '"SubagentStart"' "1 SubagentStart event key"
smoke_assert_contains "$hooks_content" '"SubagentStop"' "1 SubagentStop event key"
smoke_assert_contains "$hooks_content" "codex-subagent-start.py" "1 start wired"
smoke_assert_contains "$hooks_content" "codex-subagent-stop.py" "1 stop wired"

# ---------------------------------------------------------------------------
# Test 2 — SubagentStart audits the fan-out (no decision)
# ---------------------------------------------------------------------------
smoke_log "2. SubagentStart audits subagent_fanout/start"

: >"$AUDIT_LOG"
# Event carries a hostile raw 'prompt' + 'argv' field that MUST NOT be persisted.
start_event='{"subagent_name":"worker-a","subagent_id":"th-7","description":"do the thing","prompt":"SECRETPROMPTBODY-/Users/secret/file","argv":["rm","-rf","/Users/secret"]}'
rc=0
out="$(run_subagent_hook "$HOOKS_DIR/codex-subagent-start.py" "$start_event")" || rc=$?
smoke_assert_eq "0" "$rc" "2 exit 0 (never constrains fan-out)"
smoke_assert_contains "$out" '"hookEventName": "SubagentStart"' "2 envelope event name"
smoke_assert_not_contains "$out" "permissionDecision" "2 no decision"
audit_content="$(cat "$AUDIT_LOG")"
smoke_assert_contains "$audit_content" '"action": "subagent_fanout"' "2 audit action"
smoke_assert_contains "$audit_content" '"phase": "start"' "2 audit phase=start"
smoke_assert_contains "$audit_content" "worker-a" "2 subagent name recorded"
# Redaction: the raw prompt body + secret path must NOT be in the audit row.
smoke_assert_not_contains "$audit_content" "SECRETPROMPTBODY" "2 raw prompt not persisted"
smoke_assert_not_contains "$audit_content" "/Users/secret" "2 raw path not persisted"

# ---------------------------------------------------------------------------
# Test 3 — SubagentStop audits the completion (no decision)
# ---------------------------------------------------------------------------
smoke_log "3. SubagentStop audits subagent_fanout/stop"

: >"$AUDIT_LOG"
stop_event='{"subagent_name":"worker-a","subagent_id":"th-7","status":"completed","summary":"finished cleanly","last_message":"SECRETLASTMESSAGE-/Users/secret/file"}'
rc=0
out="$(run_subagent_hook "$HOOKS_DIR/codex-subagent-stop.py" "$stop_event")" || rc=$?
smoke_assert_eq "0" "$rc" "3 exit 0"
smoke_assert_contains "$out" '"hookEventName": "SubagentStop"' "3 envelope event name"
audit_content="$(cat "$AUDIT_LOG")"
smoke_assert_contains "$audit_content" '"phase": "stop"' "3 audit phase=stop"
smoke_assert_contains "$audit_content" '"status": "completed"' "3 status recorded"
smoke_assert_not_contains "$audit_content" "SECRETLASTMESSAGE" "3 raw last message not persisted"
smoke_assert_not_contains "$audit_content" "/Users/secret" "3 raw path not persisted"

# ---------------------------------------------------------------------------
# Test 4 — no BRIDGE_AGENT_ID → empty envelope, no audit
# ---------------------------------------------------------------------------
smoke_log "4. no agent id → no-op envelope"

for hook in codex-subagent-start codex-subagent-stop; do
  : >"$AUDIT_LOG"
  rc=0
  out="$(printf '%s' '{}' | env -u BRIDGE_AGENT_ID \
    BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
    BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
    python3 "$HOOKS_DIR/$hook.py")" || rc=$?
  smoke_assert_eq "0" "$rc" "4 $hook exit 0 without agent"
  smoke_assert_contains "$out" '"hookSpecificOutput"' "4 $hook well-formed envelope"
  [[ -s "$AUDIT_LOG" ]] && smoke_fail "4: $hook expected no audit row without agent id" || true
done

smoke_log "PASS: $SMOKE_NAME"
