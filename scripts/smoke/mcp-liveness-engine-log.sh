#!/usr/bin/env bash
# scripts/smoke/mcp-liveness-engine-log.sh — issue #2021 regression smoke.
#
# Accept the Claude engine MCP-log connect+register evidence as a SECOND
# plugin-liveness signal, with the descendant PROCESS probe staying PRIMARY.
# Re-implementation of community PR #1770 by @sankyul (credited) — this smoke
# reuses @sankyul's fabricated-cache shape and extends it with the tri-state
# routing matrix the rc2 brief mandates.
#
# Two layers are exercised, both in an isolated BRIDGE_HOME/cache tree that
# never launches or restarts a live agent:
#
#   A. The engine-log helper directly (bridge_plugin_mcp_engine_log_ready_for_item):
#      the current-session scoping + workdir + start-time binding, incl. the
#      KEY false-positive guard — a stale/previous session's log must NOT pass.
#
#   B. The integrated decision (bridge_agent_plugin_mcp_alive_for_item) with the
#      descendant probe forced to each tri-state:
#        - probe ALIVE (rc 0)        -> alive regardless of log (probe primary)
#        - probe DEAD  (rc 1)        -> dead even with a good current-session
#                                       log (log must NOT override a clean
#                                       negative)
#        - probe INCONCLUSIVE (rc 2) + good current-session log -> alive
#        - probe INCONCLUSIVE (rc 2) + missing/stale log        -> dead
#      Plus a mutation check: with the log consult removed, the
#      inconclusive+good-log case wrongly stays dead — proving the rescue is
#      load-bearing.

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

# ---------------------------------------------------------------------------
# Layer A — engine-log helper in isolation.
# ---------------------------------------------------------------------------
# run_log_probe <item> <expected_session_id> [root_pid]
# root_pid defaults to the smoke shell's own PID (a live, ps-resolvable
# process so the pane-start-time temporal guard has a real anchor). Pass an
# unresolvable PID to exercise the fail-closed-without-start-time path.
run_log_probe() {
  local item="${1:-plugin:discord@claude-plugins-official}"
  local expected_session_id="${2-}"
  local root_pid="${3-}"
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_CLAUDE_NODEJS_CACHE_DIR="$CACHE_ROOT" \
  BRIDGE_PLUGIN_MCP_ENGINE_LOG_START_SLACK_SECONDS=60 \
  BRIDGE_TEST_WORKDIR="$WORKDIR" \
  BRIDGE_TEST_SESSION_ID="$expected_session_id" \
  BRIDGE_TEST_ROOT_PID="$root_pid" \
  "$SMOKE_BASH" -c '
    set -uo pipefail
    source "$1/bridge-lib.sh" >/dev/null 2>&1
    bridge_agent_engine() { printf "%s" "claude"; }
    bridge_agent_workdir() { printf "%s" "$BRIDGE_TEST_WORKDIR"; }
    bridge_agent_session_id() { printf "%s" "$BRIDGE_TEST_SESSION_ID"; }
    bridge_require_python() { :; }
    pid="${BRIDGE_TEST_ROOT_PID:-}"
    [[ -n "$pid" ]] || pid="$$"
    bridge_plugin_mcp_engine_log_ready_for_item "$3" "$4" "$pid"
  ' -- "$REPO_ROOT" "$WORKDIR" "$AGENT" "$item"
}

# Pick a numeric PID that is (almost certainly) not a live process so
# `ps -o lstart -p <pid>` cannot report a start time — exercising the
# fail-closed temporal-anchor path (codex r1).
unresolvable_pid() {
  local pid=2147480000
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid - 1))
  done
  printf '%s' "$pid"
}

assert_log_accepts_current_session() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/current.jsonl" "$(now_utc)" "$WORKDIR" "same-session" "same-session"
  run_log_probe "plugin:discord@claude-plugins-official" "same-session" \
    || smoke_fail "current-session log evidence should pass"
}

assert_log_rejects_wrong_cwd() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/wrong-cwd.jsonl" "$(now_utc)" "$SMOKE_TMP_ROOT/other" "same-session" "same-session"
  if run_log_probe "plugin:discord@claude-plugins-official" "same-session"; then
    smoke_fail "wrong-cwd log evidence should not pass"
  fi
}

assert_log_rejects_split_session() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/split-session.jsonl" "$(now_utc)" "$WORKDIR" "session-a" "session-b"
  if run_log_probe "plugin:discord@claude-plugins-official" "session-a"; then
    smoke_fail "connected/register events from different sessions should not pass"
  fi
}

# KEY false-positive guard: the marker pair is present, current-session in
# every other respect (cwd + recent), but it belongs to a DIFFERENT (prior)
# Claude session id. Current-session scoping must reject it as DEAD.
assert_log_rejects_stale_prior_session() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/prior.jsonl" "$(now_utc)" "$WORKDIR" "old-session" "old-session"
  if run_log_probe "plugin:discord@claude-plugins-official" "current-session"; then
    smoke_fail "stale PRIOR-session log evidence must not yield false-alive"
  fi
}

assert_log_rejects_old_timestamp() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/stale-ts.jsonl" "2000-01-01T00:00:00Z" "$WORKDIR" "same-session" "same-session"
  if run_log_probe "plugin:discord@claude-plugins-official" "same-session"; then
    smoke_fail "pre-session-start (old timestamp) log evidence should not pass"
  fi
}

assert_log_fails_closed_without_session_id() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/current.jsonl" "$(now_utc)" "$WORKDIR" "same-session" "same-session"
  if run_log_probe "plugin:discord@claude-plugins-official" ""; then
    smoke_fail "unresolvable session id must fail closed (fall back to probe verdict)"
  fi
}

# codex r1: an otherwise-good current-session log must NOT pass when the pane
# start time is unreadable (`ps -o lstart` fails for a dead PID) — without a
# temporal anchor we cannot reject pre-restart evidence, so the helper must
# fail closed to the probe verdict rather than promote inconclusive -> alive.
assert_log_fails_closed_without_start_time() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/current.jsonl" "$(now_utc)" "$WORKDIR" "same-session" "same-session"
  if run_log_probe "plugin:discord@claude-plugins-official" "same-session" "$(unresolvable_pid)"; then
    smoke_fail "unresolvable pane start time must fail closed (no temporal anchor)"
  fi
}

assert_log_rejects_unprobeable_item() {
  rm -f "$LOG_DIR"/*.jsonl
  write_log "$LOG_DIR/current.jsonl" "$(now_utc)" "$WORKDIR" "same-session" "same-session"
  if run_log_probe "plugin:unknown@marketplace" "same-session"; then
    smoke_fail "unprobeable plugin item should not pass the engine-log probe"
  fi
}

# ---------------------------------------------------------------------------
# Layer B — integrated tri-state routing in bridge_agent_plugin_mcp_alive_for_item.
# The descendant probe is stubbed to a forced rc; the engine-log helper is
# stubbed (or not) so we assert the ROUTING, not the log internals (those are
# covered in Layer A). `mutate=1` removes the engine-log consult.
# ---------------------------------------------------------------------------
run_alive() {
  local probe_rc="$1"
  local log_rc="$2"
  local mutate="${3:-0}"
  local mutate_block=""
  if [[ "$mutate" == "1" ]]; then
    # Mutation: re-define the decision so the inconclusive arm falls straight
    # through to the probe verdict (return 1) WITHOUT consulting the engine
    # log — i.e. as if the #2021 rescue was never wired.
    mutate_block='
      bridge_agent_plugin_mcp_alive_for_item() {
        local rc=0
        bridge_plugin_mcp_descendant_ready_for_item 424242 "x" || rc=$?
        [[ "$rc" == "0" ]] && return 0
        return 1
      }'
  fi
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_TEST_PROBE_RC="$probe_rc" \
  BRIDGE_TEST_LOG_RC="$log_rc" \
  BRIDGE_TEST_MUTATE_BLOCK="$mutate_block" \
  "$SMOKE_BASH" -c '
    set -uo pipefail
    source "$1/bridge-lib.sh" >/dev/null 2>&1
    bridge_agent_engine() { printf "%s" "claude"; }
    bridge_agent_session() { printf "%s" "sess"; }
    bridge_tmux_session_exists() { return 0; }
    bridge_tmux_session_pane_pid() { printf "%s" "424242"; }
    bridge_plugin_mcp_descendant_ready_for_item() { return "$BRIDGE_TEST_PROBE_RC"; }
    bridge_plugin_mcp_engine_log_ready_for_item() { return "$BRIDGE_TEST_LOG_RC"; }
    eval "$BRIDGE_TEST_MUTATE_BLOCK"
    bridge_agent_plugin_mcp_alive_for_item probe-agent "plugin:discord@claude-plugins-official"
  ' -- "$REPO_ROOT"
}

assert_probe_alive_wins() {
  # Probe alive (0); log would say dead (1) — alive regardless of the log.
  run_alive 0 1 || smoke_fail "conclusive-alive probe must report alive (probe primary)"
}

assert_probe_dead_not_rescued_by_log() {
  # Probe conclusively dead (1); log would say alive (0) — must stay DEAD.
  if run_alive 1 0; then
    smoke_fail "conclusive-dead probe must NOT be overridden by engine-log evidence"
  fi
}

assert_inconclusive_rescued_by_good_log() {
  # Probe inconclusive (2); current-session log confirms (0) — alive.
  run_alive 2 0 || smoke_fail "inconclusive probe + good current-session log should report alive"
}

assert_inconclusive_dead_without_log() {
  # Probe inconclusive (2); log cannot confirm (1) — falls back to dead.
  if run_alive 2 1; then
    smoke_fail "inconclusive probe + missing log evidence must report dead (no false-alive)"
  fi
}

assert_mutation_breaks_rescue() {
  # With the engine-log consult removed, the inconclusive+good-log case that
  # passed in assert_inconclusive_rescued_by_good_log now wrongly reports dead.
  if run_alive 2 0 1; then
    smoke_fail "mutation guard: removing the log consult should regress the rescue (expected dead)"
  fi
}

smoke_run "A: accept current-session engine log evidence" assert_log_accepts_current_session
smoke_run "A: reject wrong cwd" assert_log_rejects_wrong_cwd
smoke_run "A: reject split-session evidence" assert_log_rejects_split_session
smoke_run "A: reject stale PRIOR-session log (false-positive guard)" assert_log_rejects_stale_prior_session
smoke_run "A: reject pre-session-start timestamp" assert_log_rejects_old_timestamp
smoke_run "A: fail closed without a session id" assert_log_fails_closed_without_session_id
smoke_run "A: fail closed without a pane start time" assert_log_fails_closed_without_start_time
smoke_run "A: reject unprobeable item" assert_log_rejects_unprobeable_item
smoke_run "B: conclusive-alive probe wins (probe primary)" assert_probe_alive_wins
smoke_run "B: conclusive-dead probe not rescued by log" assert_probe_dead_not_rescued_by_log
smoke_run "B: inconclusive probe rescued by good current-session log" assert_inconclusive_rescued_by_good_log
smoke_run "B: inconclusive probe + no log -> dead" assert_inconclusive_dead_without_log
smoke_run "B: mutation removes rescue -> regresses to dead" assert_mutation_breaks_rescue

smoke_log "mcp-liveness-engine-log: ALL TESTS PASS"
