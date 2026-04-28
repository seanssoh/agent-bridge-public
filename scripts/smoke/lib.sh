#!/usr/bin/env bash
# shellcheck shell=bash

SMOKE_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SMOKE_REPO_ROOT="$(cd -P "$SMOKE_LIB_DIR/../.." && pwd -P)"
SMOKE_NAME="${SMOKE_NAME:-$(basename "$0" .sh)}"
SMOKE_TMP_ROOT="${SMOKE_TMP_ROOT:-}"

smoke_log() {
  printf '[smoke:%s] %s\n' "$SMOKE_NAME" "$*"
}

smoke_fail() {
  printf '[smoke:%s][error] %s\n' "$SMOKE_NAME" "$*" >&2
  exit 1
}

smoke_require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || smoke_fail "missing required command: $cmd"
}

smoke_make_temp_root() {
  local label="${1:-$SMOKE_NAME}"
  SMOKE_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-${label}.XXXXXX")"
  SMOKE_TMP_ROOT="$(cd -P "$SMOKE_TMP_ROOT" && pwd -P)"
  export SMOKE_TMP_ROOT
}

smoke_setup_bridge_home() {
  local label="${1:-$SMOKE_NAME}"
  smoke_make_temp_root "$label"

  export BRIDGE_HOME="$SMOKE_TMP_ROOT/bridge-home"
  export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
  export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
  export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
  export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
  export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
  export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
  export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
  export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
  export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
  export BRIDGE_RUNTIME_ROOT="$BRIDGE_HOME/runtime"
  export BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/bridge-config.json"
  export BRIDGE_HOOKS_DIR="$BRIDGE_HOME/hooks"
  export BRIDGE_AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"

  mkdir -p \
    "$BRIDGE_HOME" \
    "$BRIDGE_STATE_DIR" \
    "$BRIDGE_LOG_DIR" \
    "$BRIDGE_SHARED_DIR" \
    "$BRIDGE_ACTIVE_AGENT_DIR" \
    "$BRIDGE_HISTORY_DIR" \
    "$BRIDGE_AGENT_HOME_ROOT" \
    "$BRIDGE_RUNTIME_ROOT" \
    "$BRIDGE_HOOKS_DIR"
  : >"$BRIDGE_ROSTER_FILE"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
}

smoke_cleanup_temp_root() {
  local root="${SMOKE_TMP_ROOT:-}"
  if [[ -n "$root" && -d "$root" ]]; then
    rm -rf "$root" >/dev/null 2>&1 || true
  fi
}

smoke_assert_eq() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  [[ "$actual" == "$expected" ]] || smoke_fail "$context: expected '$expected', got '$actual'"
}

smoke_assert_match() {
  local actual="$1"
  local regex="$2"
  local context="$3"
  [[ "$actual" =~ $regex ]] || smoke_fail "$context: expected match /$regex/, got '$actual'"
}

smoke_assert_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"
  [[ "$haystack" == *"$needle"* ]] || smoke_fail "$context: expected output to contain '$needle', got: $haystack"
}

smoke_assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"
  [[ "$haystack" != *"$needle"* ]] || smoke_fail "$context: expected output not to contain '$needle', got: $haystack"
}

smoke_assert_file_exists() {
  local path="$1"
  local context="$2"
  [[ -f "$path" ]] || smoke_fail "$context: expected file to exist: $path"
}

smoke_shell_field() {
  local key="$1"
  local payload="$2"
  printf '%s\n' "$payload" | sed -n "s/^${key}=//p" | head -n 1 | sed "s/^'//; s/'$//"
}

smoke_run() {
  local label="$1"
  shift
  smoke_log "setup/act/assert: $label"
  "$@"
  smoke_log "ok: $label"
}
