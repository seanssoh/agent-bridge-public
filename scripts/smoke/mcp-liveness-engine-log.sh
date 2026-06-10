#!/usr/bin/env bash
# scripts/smoke/mcp-liveness-engine-log.sh — issue #69 regression smoke.
#
# Exercises bridge_plugin_mcp_engine_log_ready_for_item with a fabricated
# Claude CLI MCP cache. This stays in an isolated BRIDGE_HOME/cache tree and
# never launches or restarts a live agent.

set -uo pipefail

SMOKE_NAME="mcp-liveness-engine-log"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENT="probe-agent"
WORKDIR="$SMOKE_TMP_ROOT/workdir"
CACHE_ROOT="$SMOKE_TMP_ROOT/cache"
LOG_DIR="$CACHE_ROOT/-tmp-probe/mcp-logs-plugin-discord-discord"
mkdir -p "$WORKDIR" "$LOG_DIR"

if [[ -n "${BASH_BIN:-}" ]]; then
  SMOKE_BASH="$BASH_BIN"
elif [[ -x /opt/homebrew/bin/bash ]]; then
  SMOKE_BASH="/opt/homebrew/bin/bash"
elif [[ -x /usr/local/bin/bash ]]; then
  SMOKE_BASH="/usr/local/bin/bash"
else
  SMOKE_BASH="$(command -v bash)"
fi
[[ -n "$SMOKE_BASH" && -x "$SMOKE_BASH" ]] || smoke_fail "no bash binary found"

now_utc() {
  python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
PY
}

write_log() {
  local path="$1"
  local timestamp="$2"
  local cwd="$3"
  local sid_connected="$4"
  local sid_registered="$5"
  cat >"$path" <<EOF
{"debug":"Successfully connected (transport: stdio) in 12ms","timestamp":"$timestamp","sessionId":"$sid_connected","cwd":"$cwd"}
{"debug":"Channel notifications registered","timestamp":"$timestamp","sessionId":"$sid_registered","cwd":"$cwd"}
EOF
}

write_log_without_timestamp() {
  local path="$1"
  local cwd="$2"
  local sid="$3"
  cat >"$path" <<EOF
{"debug":"Successfully connected (transport: stdio) in 12ms","sessionId":"$sid","cwd":"$cwd"}
{"debug":"Channel notifications registered","sessionId":"$sid","cwd":"$cwd"}
EOF
}

write_log_without_cwd() {
  local path="$1"
  local timestamp="$2"
  local sid="$3"
  cat >"$path" <<EOF
{"debug":"Successfully connected (transport: stdio) in 12ms","timestamp":"$timestamp","sessionId":"$sid"}
{"debug":"Channel notifications registered","timestamp":"$timestamp","sessionId":"$sid"}
EOF
}

run_probe() {
  local item="${1:-plugin:discord@claude-plugins-official}"
  local expected_session_id="${2-}"
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_CLAUDE_NODEJS_CACHE_DIR="$CACHE_ROOT" \
  BRIDGE_PLUGIN_MCP_ENGINE_LOG_START_SLACK_SECONDS=60 \
  BRIDGE_TEST_WORKDIR="$WORKDIR" \
  BRIDGE_TEST_SESSION_ID="$expected_session_id" \
  "$SMOKE_BASH" -c '
    set -uo pipefail
    source "$1/bridge-lib.sh" >/dev/null 2>&1
    bridge_agent_engine() { printf "%s" "claude"; }
    bridge_agent_workdir() { printf "%s" "$BRIDGE_TEST_WORKDIR"; }
    bridge_agent_session_id() { printf "%s" "$BRIDGE_TEST_SESSION_ID"; }
    bridge_require_python() { :; }
    bridge_plugin_mcp_engine_log_ready_for_item "$3" "$4" "$$"
  ' -- "$REPO_ROOT" "$WORKDIR" "$AGENT" "$item"
}

assert_accepts_current_session_log() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/current.jsonl" "$(now_utc)" "$WORKDIR" "same-session" "same-session"
  run_probe "plugin:discord@claude-plugins-official" "same-session" || smoke_fail "current-session log evidence should pass"
}

assert_rejects_wrong_cwd() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/wrong-cwd.jsonl" "$(now_utc)" "$SMOKE_TMP_ROOT/other" "same-session" "same-session"
  if run_probe "plugin:discord@claude-plugins-official" "same-session"; then
    smoke_fail "wrong-cwd log evidence should not pass"
  fi
}

assert_rejects_split_session_evidence() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/split-session.jsonl" "$(now_utc)" "$WORKDIR" "session-a" "session-b"
  if run_probe "plugin:discord@claude-plugins-official" "session-a"; then
    smoke_fail "connected/register events from different sessions should not pass"
  fi
}

assert_rejects_wrong_current_session() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/current.jsonl" "$(now_utc)" "$WORKDIR" "same-session" "same-session"
  if run_probe "plugin:discord@claude-plugins-official" "other-session"; then
    smoke_fail "log evidence for another Claude session should not pass"
  fi
}

assert_rejects_stale_log() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/stale.jsonl" "2000-01-01T00:00:00Z" "$WORKDIR" "same-session" "same-session"
  if run_probe "plugin:discord@claude-plugins-official" "same-session"; then
    smoke_fail "stale pre-session log evidence should not pass"
  fi
}

assert_rejects_missing_timestamp() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log_without_timestamp "$LOG_DIR/no-timestamp.jsonl" "$WORKDIR" "same-session"
  if run_probe "plugin:discord@claude-plugins-official" "same-session"; then
    smoke_fail "missing-timestamp log evidence should not pass"
  fi
}

assert_rejects_empty_expected_session() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/current.jsonl" "$(now_utc)" "$WORKDIR" "same-session" "same-session"
  if run_probe "plugin:discord@claude-plugins-official" ""; then
    smoke_fail "unbound expected session id should fail closed"
  fi
}

assert_rejects_missing_cwd() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log_without_cwd "$LOG_DIR/no-cwd.jsonl" "$(now_utc)" "same-session"
  if run_probe "plugin:discord@claude-plugins-official" "same-session"; then
    smoke_fail "missing-cwd log evidence should not pass"
  fi
}

assert_rejects_unprobeable_item() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/current.jsonl" "$(now_utc)" "$WORKDIR" "same-session" "same-session"
  if run_probe "plugin:unknown@marketplace" "same-session"; then
    smoke_fail "unprobeable plugin item should not pass"
  fi
}

smoke_run "accept current-session engine log evidence" assert_accepts_current_session_log
smoke_run "reject wrong cwd" assert_rejects_wrong_cwd
smoke_run "reject split session evidence" assert_rejects_split_session_evidence
smoke_run "reject wrong current session" assert_rejects_wrong_current_session
smoke_run "reject stale log" assert_rejects_stale_log
smoke_run "reject missing timestamp" assert_rejects_missing_timestamp
smoke_run "reject empty expected session" assert_rejects_empty_expected_session
smoke_run "reject missing cwd" assert_rejects_missing_cwd
smoke_run "reject unprobeable item" assert_rejects_unprobeable_item

smoke_log "mcp-liveness-engine-log: ALL TESTS PASS"
