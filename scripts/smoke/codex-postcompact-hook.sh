#!/usr/bin/env bash
# scripts/smoke/codex-postcompact-hook.sh — Codex PostCompact hook smoke (#8945 Track B).
#
# Validates hooks/codex-post-compact.py:
# 1. ensure-codex-hooks wires the PostCompact event at codex-post-compact.py.
# 2. On a synthetic PostCompact event the hook:
#      - emits a well-formed Codex envelope (hookEventName=PostCompact) whose
#        additionalContext re-injects the queue protocol + canonical context,
#      - exits 0 (never blocks),
#      - refreshes a per-agent heartbeat marker,
#      - emits a codex_post_compact.recover audit row.
# 3. No BRIDGE_AGENT_ID → empty envelope, exit 0, no audit row.
#
# Audit-only by default: the hook emits NO permissionDecision and never blocks.

set -euo pipefail

SMOKE_NAME="codex-postcompact-hook"
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
TEST_AGENT="codex-postcompact-smoke"
AGENT_HOME="$BRIDGE_HOME/agents/$TEST_AGENT"
mkdir -p "$AGENT_HOME"
printf '# soul\nload-bearing identity anchor\n' >"$AGENT_HOME/SOUL.md"

# ---------------------------------------------------------------------------
# Test 1 — ensure-codex-hooks wires PostCompact
# ---------------------------------------------------------------------------
smoke_log "1. ensure-codex-hooks wires PostCompact"

CODEX_HOOKS_FILE="$SMOKE_TMP_ROOT/codex-hooks.json"
python3 "$REPO_ROOT/bridge-hooks.py" ensure-codex-hooks \
  --bridge-home "$REPO_ROOT" --python-bin "$PYTHON_BIN" \
  --codex-hooks-file "$CODEX_HOOKS_FILE" --format text >/dev/null 2>&1 \
  || smoke_fail "1: ensure-codex-hooks failed"
hooks_content="$(cat "$CODEX_HOOKS_FILE")"
smoke_assert_contains "$hooks_content" '"PostCompact"' "1 PostCompact event key"
smoke_assert_contains "$hooks_content" "codex-post-compact.py" "1 PostCompact wired"

# ---------------------------------------------------------------------------
# Test 2 — synthetic PostCompact event → re-inject + heartbeat + audit
# ---------------------------------------------------------------------------
smoke_log "2. PostCompact re-injects context + heartbeat"

AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
mkdir -p "$(dirname "$AUDIT_LOG")"
: >"$AUDIT_LOG"

OUT_FILE="$SMOKE_TMP_ROOT/post-out.json"
rc=0
printf '%s' '{}' | env \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents" \
  BRIDGE_AGENT_ID="$TEST_AGENT" \
  python3 "$HOOKS_DIR/codex-post-compact.py" >"$OUT_FILE" || rc=$?
smoke_assert_eq "0" "$rc" "2 exit 0 (never blocks)"

# Parse the envelope with python3 so embedded newlines in additionalContext
# (valid JSON) do not trip a shell-side grep.
event_name="$(python3 -c "import json,sys; print(json.load(open('$OUT_FILE'))['hookSpecificOutput']['hookEventName'])")"
smoke_assert_eq "PostCompact" "$event_name" "2 envelope event name"
ctx_has_queue="$(python3 -c "import json; ctx=json.load(open('$OUT_FILE'))['hookSpecificOutput']['additionalContext']; print('yes' if 'queue protocol' in ctx else 'no')")"
smoke_assert_eq "yes" "$ctx_has_queue" "2 queue protocol re-injected"
smoke_assert_not_contains "$(cat "$OUT_FILE")" "permissionDecision" "2 no permission decision"

smoke_assert_file_exists "$BRIDGE_STATE_DIR/agents/$TEST_AGENT/codex-post-compact.json" \
  "2 heartbeat marker written"
audit_content="$(cat "$AUDIT_LOG")"
smoke_assert_contains "$audit_content" "codex_post_compact.recover" "2 audit row action"
smoke_assert_contains "$audit_content" '"heartbeat_refreshed": true' "2 heartbeat audited"

# ---------------------------------------------------------------------------
# Test 3 — no BRIDGE_AGENT_ID → empty envelope, no audit
# ---------------------------------------------------------------------------
smoke_log "3. no agent id → no-op envelope"

: >"$AUDIT_LOG"
rc=0
out="$(printf '%s' '{}' | env -u BRIDGE_AGENT_ID \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  python3 "$HOOKS_DIR/codex-post-compact.py")" || rc=$?
smoke_assert_eq "0" "$rc" "3 exit 0 without agent"
smoke_assert_contains "$out" '"hookEventName": "PostCompact"' "3 still well-formed envelope"
[[ -s "$AUDIT_LOG" ]] && smoke_fail "3: expected no audit row without agent id" || true

smoke_log "PASS: $SMOKE_NAME"
