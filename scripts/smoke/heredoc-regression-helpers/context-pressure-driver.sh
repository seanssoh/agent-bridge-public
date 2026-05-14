#!/usr/bin/env bash
# scripts/smoke/heredoc-regression-helpers/context-pressure-driver.sh
#
# Driver for case 3 of scripts/smoke/heredoc-regression.sh — invokes the
# extracted process_context_pressure_reports + sibling functions from
# bridge-daemon.sh against a synthetic agent summary row and asserts the
# expected state + audit-log entries.
#
# Shipped as a tracked file rather than embedded as a heredoc-to-file
# `cat <<EOF >$driver` body inside the smoke wrapper — heredoc-to-file
# with a multi-line body is the same Bash 5.3.9 heredoc_write deadlock
# class the fixture itself is guarding against (see
# `feedback_bash_heredoc_write_class_recurrence.md` and PR #800).
#
# Invocation:
#   bash scripts/smoke/heredoc-regression-helpers/context-pressure-driver.sh \
#     <state_dir> <audit_file> <helper>
#
# Where:
#   state_dir  — tempdir for per-agent .env state files
#   audit_file — append-only audit log captured by bridge_audit_log stub
#   helper     — file containing the bridge_clear_context_pressure_state /
#                bridge_note_context_pressure_state /
#                process_context_pressure_reports definitions extracted
#                from bridge-daemon.sh by awk

set -euo pipefail
state_dir="$1"
audit_file="$2"
helper="$3"
SCRIPT_DIR="$PWD"
export BRIDGE_CONTEXT_PRESSURE_SCAN_ENABLED=1
export BRIDGE_CONTEXT_PRESSURE_SCAN_INTERVAL_SECONDS=0
mkdir -p "$state_dir"

analysis_severity=""
analysis_hash=""
analysis_pattern=""
agent_source_mode="static"
capture_empty=0

bridge_agent_context_pressure_state_file() {
  printf "%s/%s.env" "$state_dir" "$1"
}

bridge_audit_log() {
  local actor="$1"
  local action="$2"
  local target="$3"
  shift 3
  {
    printf "%s|%s|%s" "$actor" "$action" "$target"
    for item in "$@"; do
      printf "|%s" "$item"
    done
    printf "\n"
  } >>"$audit_file"
}

bridge_tmux_session_exists() { return 0; }
bridge_capture_recent() {
  (( capture_empty == 1 )) && return 0
  printf "Context remaining 8%%. Please compact soon."
}
bridge_with_timeout() {
  cat >/dev/null || true
  [[ -n "$analysis_severity" ]] || return 0
  printf "CONTEXT_PRESSURE_SEVERITY=%q\n" "$analysis_severity"
  printf "CONTEXT_PRESSURE_MATCHED_PATTERN=%q\n" "$analysis_pattern"
  printf "CONTEXT_PRESSURE_EXCERPT_HASH=%q\n" "$analysis_hash"
}
bridge_agent_source() { printf "%s" "$agent_source_mode"; }
bridge_queue_cli() { echo "bridge_queue_cli should not be called"; exit 99; }
bridge_notify_send() { echo "bridge_notify_send should not be called"; exit 99; }
daemon_info() { :; }
daemon_source_state_file() {
  # shellcheck source=/dev/null
  source "$1" 2>/dev/null
}

# shellcheck disable=SC1090
source "$helper"

summary_static=$'static-agent\t0\t0\t0\t1\t0\t0\t0\tstatic-session\tclaude\t/tmp'

analysis_severity=warning
analysis_hash=hash-static
analysis_pattern=hud:context_pct=72
agent_source_mode=static
process_context_pressure_reports "$summary_static" >/dev/null
static_state="$(cat "$state_dir/static-agent.env")"
[[ "$static_state" == *"CONTEXT_PRESSURE_SEVERITY=warning"* ]] || { echo "static severity missing"; exit 1; }
[[ "$static_state" == *"CONTEXT_PRESSURE_EXCERPT_HASH=hash-static"* ]] || { echo "static hash missing"; exit 1; }
grep -q "daemon|context_pressure_detected|static-agent|--detail|severity=warning" "$audit_file" || { echo "static detected audit missing"; exit 1; }

echo ok
