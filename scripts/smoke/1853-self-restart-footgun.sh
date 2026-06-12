#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1853-self-restart-footgun.sh — Issue #1853.
#
# `agent restart <self>` invoked from INSIDE the target session's process
# tree (the agent's own Claude session, or a background child it spawned —
# e.g. `sleep 60 && agent-bridge agent restart <self>`) used to saw off its
# own branch: bridge_kill_agent_session takes down the whole tmux session,
# including the process running run_restart, so the relaunch leg never fires.
# The agent stayed down until the daemon's always-on ensure revived it FRESH
# (no #1769 trusted-resume marker consumed, conversation continuity lost).
#
# The fix (bridge-agent.sh::run_restart + lib/bridge-agents.sh helpers):
#   1. bridge_agent_restart_is_self detects the doomed-tree case via two
#      independent signals: BRIDGE_AGENT_ID == <agent>, OR tmux ancestry
#      (running inside the target session's pane). The detached worker
#      (BRIDGE_RESTART_DETACHED=1) is explicitly NOT self — it has escaped
#      the doomed tree and must complete the normal kill→relaunch.
#   2. bridge_agent_restart_relaunch_detached re-execs the restart via
#      setsid/nohup with BRIDGE_RESTART_DETACHED=1 so the survivor — outside
#      the doomed tree — owns the full marker→kill→relaunch sequence
#      atomically, preserving resume.
#   3. bridge_agent_restart_self_unsupported_guidance is the fail-closed
#      fallback when no detach tool exists: non-destructive, points at the
#      out-of-band restart path.
#
# Test plan (bash helpers only, no live tmux/kill):
#   T1. is_self returns 0 when BRIDGE_AGENT_ID == agent.
#   T2. is_self returns 1 (not self) when BRIDGE_AGENT_ID differs and we are
#       not inside the target session's tmux pane.
#   T3. is_self returns 1 (not self) when BRIDGE_RESTART_DETACHED=1 even with
#       BRIDGE_AGENT_ID == agent — the survivor must proceed to relaunch.
#   T4. relaunch_detached spawns a worker that carries BRIDGE_RESTART_DETACHED=1
#       and the agent name + passthrough args (verified via a stub
#       bridge-agent.sh that records its env+argv).
#   T5. self_unsupported_guidance is non-destructive (states "left intact" and
#       embeds the out-of-band `agent-bridge agent restart <agent>` command).
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; never touches the
# operator's live runtime.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses no command
# substitution feeding a heredoc-stdin and no `<<<` here-strings into bridge
# functions.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (macOS ships /bin/bash 3.2).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1853-self-restart-footgun] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1853-self-restart-footgun"
SCRIPT_DIR_SMOKE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR_SMOKE/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1853-self-restart-footgun"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

for fn in \
  bridge_agent_restart_is_self \
  bridge_agent_restart_relaunch_detached \
  bridge_agent_restart_self_unsupported_guidance; do
  if ! declare -F "$fn" >/dev/null; then
    smoke_fail "$fn not defined after sourcing bridge-lib.sh"
  fi
done

# T1 — is_self true when BRIDGE_AGENT_ID matches the target agent.
test_is_self_via_agent_id() {
  local agent="sm-1853-a"
  # No tmux ancestry path: session arg empty, TMUX unset for this probe.
  if BRIDGE_RESTART_DETACHED="" TMUX="" BRIDGE_AGENT_ID="$agent" \
      bridge_agent_restart_is_self "$agent" ""; then
    : # expected
  else
    smoke_fail "T1 is_self should return 0 when BRIDGE_AGENT_ID == agent"
  fi
}

# T2 — is_self false when the caller is a different agent and not inside the
# target session's tmux pane (a controller/admin running the restart).
test_not_self_other_agent() {
  local agent="sm-1853-b"
  if BRIDGE_RESTART_DETACHED="" TMUX="" BRIDGE_AGENT_ID="some-controller" \
      bridge_agent_restart_is_self "$agent" "$agent"; then
    smoke_fail "T2 is_self should return 1 for a different caller agent outside the session"
  fi
}

# T3 — the detached survivor (BRIDGE_RESTART_DETACHED=1) is NOT self even when
# BRIDGE_AGENT_ID still matches: it has escaped the doomed tree and must run
# the normal kill→relaunch. Without this carve-out the survivor would re-detach
# forever.
test_detached_worker_not_self() {
  local agent="sm-1853-c"
  if BRIDGE_RESTART_DETACHED="1" TMUX="" BRIDGE_AGENT_ID="$agent" \
      bridge_agent_restart_is_self "$agent" "$agent"; then
    smoke_fail "T3 is_self must return 1 when BRIDGE_RESTART_DETACHED=1 (survivor proceeds)"
  fi
}

# T4 — relaunch_detached spawns a worker carrying the survival flag + argv.
# We point SCRIPT_DIR at a stub dir whose bridge-agent.sh records its env+argv
# to a file, then assert the detached invocation set BRIDGE_RESTART_DETACHED=1
# and forwarded the agent name + passthrough args.
test_relaunch_detached_invocation() {
  local agent="sm-1853-d"
  local stub_dir="$SMOKE_TMP_ROOT/stub-$agent"
  mkdir -p "$stub_dir"
  local record="$SMOKE_TMP_ROOT/relaunch-$agent.record"
  rm -f "$record"

  # Stub bridge-agent.sh: append a single line capturing the survival flag and
  # all argv, then exit cleanly so the detached worker is harmless.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "DETACHED=%%s ARGV=%%s\\n" "${BRIDGE_RESTART_DETACHED:-}" "$*" >> %q\n' "$record"
  } > "$stub_dir/bridge-agent.sh"
  chmod +x "$stub_dir/bridge-agent.sh"

  # SCRIPT_DIR and BRIDGE_BASH_BIN are read by the helper to build the re-exec.
  SCRIPT_DIR="$stub_dir" BRIDGE_BASH_BIN="$(command -v bash)" \
    bridge_agent_restart_relaunch_detached "$agent" --no-continue \
    || smoke_fail "T4 relaunch_detached returned non-zero (no detach tool?)"

  # The worker is detached/async; poll briefly for the record to appear.
  local waited=0
  while [[ ! -s "$record" && $waited -lt 50 ]]; do
    sleep 0.1
    waited=$(( waited + 1 ))
  done

  smoke_assert_file_exists "$record" "T4 detached worker ran and recorded its invocation"
  local line=""
  line="$(cat "$record")"
  smoke_assert_contains "$line" "DETACHED=1" \
    "T4 detached worker carries BRIDGE_RESTART_DETACHED=1 (survives the self-kill, no re-detach loop)"
  smoke_assert_contains "$line" "restart $agent" \
    "T4 detached worker re-runs the restart for the same agent"
  smoke_assert_contains "$line" "--no-continue" \
    "T4 detached worker forwards passthrough start args"
}

# T5 — fail-closed guidance is non-destructive and points out-of-band.
test_self_unsupported_guidance() {
  local agent="sm-1853-e"
  local guidance=""
  guidance="$(bridge_agent_restart_self_unsupported_guidance "$agent")"
  smoke_assert_contains "$guidance" "left intact" \
    "T5 guidance states the running session was left intact (non-destructive)"
  smoke_assert_contains "$guidance" "agent-bridge agent restart $agent" \
    "T5 guidance embeds the supported out-of-band restart command"
}

smoke_run "T1 is_self true via BRIDGE_AGENT_ID match"         test_is_self_via_agent_id
smoke_run "T2 is_self false for a different caller agent"     test_not_self_other_agent
smoke_run "T3 detached survivor is not treated as self"       test_detached_worker_not_self
smoke_run "T4 relaunch_detached carries survival flag + argv" test_relaunch_detached_invocation
smoke_run "T5 self-unsupported guidance is non-destructive"   test_self_unsupported_guidance

smoke_log "all checks passed"
