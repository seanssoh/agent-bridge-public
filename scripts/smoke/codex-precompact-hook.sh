#!/usr/bin/env bash
# scripts/smoke/codex-precompact-hook.sh — Codex PreCompact hook smoke (#8945 Track B).
#
# Validates hooks/codex-pre-compact.py:
# 1. ensure-codex-hooks wires the PreCompact event at codex-pre-compact.py.
# 2. On a synthetic PreCompact event the hook:
#      - emits a well-formed Codex envelope (hookEventName=PreCompact),
#      - exits 0 (never blocks compaction),
#      - writes a canonical snapshot sidecar,
#      - emits a codex_pre_compact.snapshot audit row recording the trigger
#        and whether a NEXT-SESSION.md handoff was present.
# 3. No BRIDGE_AGENT_ID → empty envelope, exit 0, no audit row.
#
# Audit-only by default: the hook emits NO permissionDecision and never blocks.

set -euo pipefail

SMOKE_NAME="codex-precompact-hook"
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
TEST_AGENT="codex-precompact-smoke"
AGENT_HOME="$BRIDGE_HOME/agents/$TEST_AGENT"
mkdir -p "$AGENT_HOME"
printf '# soul\nload-bearing identity anchor\n' >"$AGENT_HOME/SOUL.md"
printf '# memory\nremember this\n' >"$AGENT_HOME/MEMORY.md"
printf '# handoff\nread me first\n' >"$AGENT_HOME/NEXT-SESSION.md"

# ---------------------------------------------------------------------------
# Test 1 — ensure-codex-hooks wires PreCompact
# ---------------------------------------------------------------------------
smoke_log "1. ensure-codex-hooks wires PreCompact"

CODEX_HOOKS_FILE="$SMOKE_TMP_ROOT/codex-hooks.json"
python3 "$REPO_ROOT/bridge-hooks.py" ensure-codex-hooks \
  --bridge-home "$REPO_ROOT" --python-bin "$PYTHON_BIN" \
  --codex-hooks-file "$CODEX_HOOKS_FILE" --format text >/dev/null 2>&1 \
  || smoke_fail "1: ensure-codex-hooks failed"
hooks_content="$(cat "$CODEX_HOOKS_FILE")"
smoke_assert_contains "$hooks_content" '"PreCompact"' "1 PreCompact event key"
smoke_assert_contains "$hooks_content" "codex-pre-compact.py" "1 PreCompact wired"

# ---------------------------------------------------------------------------
# Test 2 — synthetic PreCompact event → snapshot + audit + envelope
# ---------------------------------------------------------------------------
smoke_log "2. PreCompact event snapshots + audits"

AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
mkdir -p "$(dirname "$AUDIT_LOG")"
: >"$AUDIT_LOG"

rc=0
out="$(printf '%s' '{"trigger":"auto"}' | env \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents" \
  BRIDGE_AGENT_ID="$TEST_AGENT" \
  python3 "$HOOKS_DIR/codex-pre-compact.py")" || rc=$?
smoke_assert_eq "0" "$rc" "2 exit 0 (never blocks)"
smoke_assert_contains "$out" '"hookEventName": "PreCompact"' "2 envelope event name"
smoke_assert_not_contains "$out" "permissionDecision" "2 no permission decision"

smoke_assert_file_exists "$BRIDGE_STATE_DIR/agents/$TEST_AGENT/compact-snapshot.json" \
  "2 canonical snapshot written"
audit_content="$(cat "$AUDIT_LOG")"
smoke_assert_contains "$audit_content" "codex_pre_compact.snapshot" "2 audit row action"
smoke_assert_contains "$audit_content" '"trigger": "auto"' "2 audit trigger"
smoke_assert_contains "$audit_content" '"next_session_present": true' "2 handoff recorded"

# ---------------------------------------------------------------------------
# Test 3 — no BRIDGE_AGENT_ID → empty envelope, no audit
# ---------------------------------------------------------------------------
smoke_log "3. no agent id → no-op envelope"

: >"$AUDIT_LOG"
rc=0
out="$(printf '%s' '{"trigger":"manual"}' | env -u BRIDGE_AGENT_ID \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  python3 "$HOOKS_DIR/codex-pre-compact.py")" || rc=$?
smoke_assert_eq "0" "$rc" "3 exit 0 without agent"
smoke_assert_contains "$out" '"hookEventName": "PreCompact"' "3 still well-formed envelope"
[[ -s "$AUDIT_LOG" ]] && smoke_fail "3: expected no audit row without agent id" || true

smoke_log "PASS: $SMOKE_NAME"
