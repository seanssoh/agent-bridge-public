#!/usr/bin/env bash
# Regression guard: linux-user isolated Claude agents cannot control the
# controller-owned tmux socket. Development-channel picker auto-accept must be
# armed from bridge-start.sh, and bridge-run.sh must skip its UID-local watcher
# when the controller watcher is present.

set -euo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
START_SH="$REPO_ROOT/bridge-start.sh"
RUN_SH="$REPO_ROOT/bridge-run.sh"

die() {
  printf '[devchannels-controller-autoaccept][error] %s\n' "$*" >&2
  exit 1
}

line_no() {
  local pattern="$1"
  local file="$2"
  local line=""

  line="$(grep -nF "$pattern" "$file" | head -n1 | cut -d: -f1 || true)"
  [[ -n "$line" ]] || die "missing pattern in ${file##*/}: $pattern"
  printf '%s' "$line"
}

assert_before() {
  local earlier="$1"
  local later="$2"
  local label="$3"

  (( earlier < later )) || die "$label order invalid: $earlier !< $later"
}

start_env_line="$(line_no 'SESSION_CMD="BRIDGE_CONTROLLER_DEV_CHANNELS_ACCEPT=1 ${SESSION_CMD}"' "$START_SH")"
sudo_wrap_line="$(line_no 'if [[ $SUDO_WRAP_ACTIVE -eq 1 ]]; then' "$START_SH")"
tmux_new_line="$(line_no 'tmux new-session -d -s "$SESSION"' "$START_SH")"
schedule_call_line="$(line_no 'bridge_start_schedule_dev_channels_accept "$SESSION" "$AGENT"' "$START_SH")"
foreground_wait_line="$(line_no 'bridge_tmux_wait_for_claude_foreground "$session" "$foreground_timeout"' "$START_SH")"
controller_wait_line="$(line_no 'if bridge_tmux_wait_for_prompt "$session" claude "$accept_timeout" 1; then' "$START_SH")"
log_dir_line="$(line_no 'log_dir="$(bridge_agent_log_dir "$agent")"' "$START_SH")"
session_exists_guard_line="$(line_no 'if ! bridge_tmux_session_exists "$session"; then' "$START_SH")"
foreground_timeout_getter_line="$(line_no 'bridge_start_dev_channels_claude_foreground_timeout()' "$START_SH")"
run_skip_line="$(line_no 'BRIDGE_CONTROLLER_DEV_CHANNELS_ACCEPT:-0' "$RUN_SH")"
run_legacy_line="$(line_no 'if ! bridge_tmux_wait_for_prompt "$session" claude "$accept_timeout" 1; then' "$RUN_SH")"

assert_before "$start_env_line" "$sudo_wrap_line" "controller flag must be embedded before sudo wrapping"
assert_before "$tmux_new_line" "$schedule_call_line" "controller watcher must be scheduled after tmux session creation"
assert_before "$session_exists_guard_line" "$foreground_wait_line" "session-exists guard must precede the foreground wait"
assert_before "$foreground_wait_line" "$controller_wait_line" "controller watcher must wait for claude foreground before waiting for prompt"
assert_before "$run_skip_line" "$run_legacy_line" "bridge-run skip must guard the legacy agent-side watcher"

[[ -n "$controller_wait_line" ]] || die "controller watcher does not allow devchannels in wait_for_prompt"
[[ -n "$log_dir_line" ]] || die "controller watcher is not logging through the agent log dir"
[[ -n "$foreground_timeout_getter_line" ]] || die "controller watcher missing foreground-timeout getter"

# Confirm both budgets are surfaced in the armed-info log line so operators see
# the split, not just a single 60s number that no longer matches reality.
grep -qF 'foreground=${foreground_timeout}s, accept=${accept_timeout}s' "$START_SH" \
  || die "controller watcher armed-info log line does not mention both timeouts (foreground + accept)"

printf '[devchannels-controller-autoaccept][ok] controller-side devchannels auto-accept wiring + foreground gate present\n'
