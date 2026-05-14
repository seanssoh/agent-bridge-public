#!/usr/bin/env bash
# scripts/smoke/status-engine-detect.sh — issue #835 Wave B regression.
#
# Guards bridge_agent_engine_process_alive (lib/bridge-tmux.sh) and the
# downstream `activity_state="starting"` branches in:
#   - lib/bridge-state.sh::bridge_write_roster_status_snapshot
#   - bridge-agent.sh::bridge_agent_activity_state
#   - bridge-daemon.sh::bridge_agent_heartbeat_activity_state
#
# Scenario, mirroring the 2026-05-14 operator wedge documented in #835:
#
#   Case 1 (tmux-without-engine): synthesize a tmux session whose pane
#   process tree contains only a `bash` shell (no claude/codex
#   descendant). Assert bridge_agent_engine_process_alive returns rc=1
#   for both engine kinds. This is the case that previously rendered as
#   `agb status` activity_state=working on a wedged static admin.
#
#   Case 2 (tmux-with-fake-engine): synthesize a tmux session that
#   spawns a process named `claude` (a symlinked `sleep` so we don't
#   require the real claude binary). Assert
#   bridge_agent_engine_process_alive returns rc=0 for engine=claude
#   and rc=1 for engine=codex (the name predicate is strict on basename).
#
#   Case 3 (no-tmux-session): no tmux session for the agent at all.
#   Assert rc=1 — preserves the "stopped" classification path.
#
#   Case 4 (matches_engine name predicate, unit-level): exercise
#   bridge_tmux_command_name_matches_engine directly so a future refactor
#   that loosens or breaks the basename match (e.g., would accept
#   `claude-foo` as the codex engine) fails here.
#
# This fixture requires `tmux` and a writable temp dir. It does NOT
# require the real claude/codex binaries — `claude` is faked via a
# symlink to `sleep` to keep the smoke hermetic. The pane process tree
# walker only looks at `ps -o comm=`, so a symlink-renamed sleep matches
# bridge_tmux_command_name_matches_engine just like a real claude would.
#
# Footgun #11 self-audit: no heredoc-stdin / here-string. Uses
# `mktemp + < file` or one-shot redirection where multi-line data
# crosses fd boundaries.

# Bash 4+ re-exec (mirrors scripts/smoke/heredoc-regression.sh shape).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:status-engine-detect] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="status-engine-detect"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

FAKE_TMUX_SESSION_1=""
FAKE_TMUX_SESSION_2=""

cleanup() {
  if [[ -n "$FAKE_TMUX_SESSION_1" ]]; then
    tmux kill-session -t "=${FAKE_TMUX_SESSION_1}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$FAKE_TMUX_SESSION_2" ]]; then
    tmux kill-session -t "=${FAKE_TMUX_SESSION_2}" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Wait briefly for a tmux session to come up and its pane process tree to
# include the expected command. tmux new-session -d returns before the
# shell has fully forked the inner command, so a tight assertion can race.
wait_for_pane_descendant() {
  local session="$1"
  local needle="$2"
  local max_attempts="${3:-25}"  # 25 * 0.1s = 2.5s, well above tmux fork latency
  local pane_pid
  local attempt
  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    pane_pid="$(tmux display-message -p -t "=${session}:" '#{pane_pid}' 2>/dev/null || true)"
    if [[ "$pane_pid" =~ ^[0-9]+$ ]]; then
      # Walk descendants the same way the production helper does; if any
      # `ps -o comm=` matches the needle, we're ready.
      local -a stack=("$pane_pid")
      local seen=" $pane_pid "
      while ((${#stack[@]} > 0)); do
        local pid="${stack[0]}"
        stack=("${stack[@]:1}")
        local comm
        comm="$(ps -o comm= -p "$pid" 2>/dev/null | awk '{$1=$1; print}' || true)"
        local base="${comm##*/}"
        if [[ "$base" == "$needle" || "$base" == "${needle}-"* ]]; then
          return 0
        fi
        local child
        while IFS= read -r child; do
          [[ "$child" =~ ^[0-9]+$ ]] || continue
          case "$seen" in
            *" $child "*) continue ;;
          esac
          seen+="$child "
          stack+=("$child")
        done < <(pgrep -P "$pid" 2>/dev/null || true)
      done
    fi
    sleep 0.1
  done
  return 1
}

# Source the production library under a stub roster. We don't need
# the full bridge_load_roster path — the engine-detect helper only
# reads BRIDGE_AGENT_SESSION and BRIDGE_AGENT_ENGINE via accessor
# functions, both of which fall back to env vars set by hand.
source_bridge_tmux() {
  # The helper file is self-contained (uses tmux + ps + pgrep + awk).
  # We do NOT want to source bridge-lib.sh because that triggers
  # bridge_load_roster against the controller's real runtime. Source
  # only the modules the helper actually depends on.
  # shellcheck source=lib/bridge-tmux.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-tmux.sh"
  # bridge_agent_engine_process_alive calls bridge_agent_session and
  # bridge_agent_engine. Provide thin per-agent stubs that the test
  # cases can populate via assoc arrays.
  declare -g -A SMOKE_AGENT_SESSION=()
  declare -g -A SMOKE_AGENT_ENGINE=()
  bridge_agent_session() { printf '%s' "${SMOKE_AGENT_SESSION[$1]-}"; }
  bridge_agent_engine() { printf '%s' "${SMOKE_AGENT_ENGINE[$1]-}"; }
}

case_name_predicate_unit() {
  # Case 4: bridge_tmux_command_name_matches_engine basename matching.
  # Run as fast unit-level assertions before the slower tmux cases.
  if ! bridge_tmux_command_name_matches_engine claude claude; then
    smoke_fail "case 4: 'claude' should match engine=claude"
  fi
  if ! bridge_tmux_command_name_matches_engine /opt/bin/claude claude; then
    smoke_fail "case 4: absolute-path 'claude' should match engine=claude"
  fi
  if ! bridge_tmux_command_name_matches_engine claude-1.2.3 claude; then
    smoke_fail "case 4: 'claude-1.2.3' should match engine=claude"
  fi
  if ! bridge_tmux_command_name_matches_engine codex codex; then
    smoke_fail "case 4: 'codex' should match engine=codex"
  fi
  if bridge_tmux_command_name_matches_engine claude codex; then
    smoke_fail "case 4: 'claude' must NOT match engine=codex"
  fi
  if bridge_tmux_command_name_matches_engine bash claude; then
    smoke_fail "case 4: 'bash' must NOT match engine=claude"
  fi
  if bridge_tmux_command_name_matches_engine sleep codex; then
    smoke_fail "case 4: 'sleep' must NOT match engine=codex"
  fi
  if bridge_tmux_command_name_matches_engine claude shell; then
    smoke_fail "case 4: engine=shell (unknown) must always return 1"
  fi
  if bridge_tmux_command_name_matches_engine "" claude; then
    smoke_fail "case 4: empty command name must return 1"
  fi
}

case_no_tmux_session() {
  # Case 3: agent declared but has no tmux session at all.
  SMOKE_AGENT_SESSION["ghost-agent"]="nonexistent-session-$$"
  SMOKE_AGENT_ENGINE["ghost-agent"]="claude"

  if bridge_agent_engine_process_alive ghost-agent claude; then
    smoke_fail "case 3: expected rc=1 (no tmux session), got rc=0"
  fi

  # Engine inferred from the stub:
  if bridge_agent_engine_process_alive ghost-agent; then
    smoke_fail "case 3 (inferred engine): expected rc=1 (no tmux session), got rc=0"
  fi
}

case_tmux_without_engine() {
  # Case 1: synthesize a tmux session running only `bash` (which then
  # tail-blocks on a long sleep so the pane doesn't exit before the
  # assertion runs). No `claude`/`codex` descendant — this is the
  # operator's #835 wedge shape.
  FAKE_TMUX_SESSION_1="agb-smoke-no-engine-$$-${RANDOM}"
  # `tmux new-session -d` returns once the session is created; the
  # inner command (`bash -c 'exec sleep ...'`) runs detached. We use
  # `exec` so the pane PID == the sleep PID (no extra bash layer to
  # walk). This is intentional: the pane root is just `sleep`, and
  # there is no engine descendant under it.
  tmux new-session -d -s "$FAKE_TMUX_SESSION_1" \
    "bash -c 'exec sleep 30'"

  if ! tmux has-session -t "=${FAKE_TMUX_SESSION_1}" 2>/dev/null; then
    smoke_fail "case 1: tmux session '$FAKE_TMUX_SESSION_1' did not come up"
  fi

  # Wait for the inner `sleep` to actually replace the bash shell so
  # `ps -o comm=` against the pane_pid sees `sleep` (the post-exec
  # comm). On macOS this is essentially instant; CI Linux containers
  # under load can take a few hundred ms.
  wait_for_pane_descendant "$FAKE_TMUX_SESSION_1" sleep 25 || \
    smoke_fail "case 1: pane never reached the inner 'sleep' command"

  SMOKE_AGENT_SESSION["wedge-agent"]="$FAKE_TMUX_SESSION_1"
  SMOKE_AGENT_ENGINE["wedge-agent"]="claude"

  if bridge_agent_engine_process_alive wedge-agent claude; then
    smoke_fail "case 1: expected rc=1 (no claude in pane tree), got rc=0"
  fi
  if bridge_agent_engine_process_alive wedge-agent codex; then
    smoke_fail "case 1: expected rc=1 (no codex in pane tree), got rc=0"
  fi
}

case_tmux_with_fake_engine() {
  # Case 2: synthesize a tmux session whose inner command is `sleep`
  # invoked by basename `claude` (via a symlink). The process-tree
  # walker only inspects `ps -o comm=` (kernel-truthful comm), so a
  # symlink-renamed `sleep` shows comm=`claude` just like the real
  # binary would. This keeps the smoke hermetic.
  local fake_bin_dir="$SMOKE_TMP_ROOT/fake-bin"
  mkdir -p "$fake_bin_dir"
  ln -sf "$(command -v sleep)" "$fake_bin_dir/claude"

  FAKE_TMUX_SESSION_2="agb-smoke-with-engine-$$-${RANDOM}"
  tmux new-session -d -s "$FAKE_TMUX_SESSION_2" \
    "bash -c 'exec \"$fake_bin_dir/claude\" 30'"

  if ! tmux has-session -t "=${FAKE_TMUX_SESSION_2}" 2>/dev/null; then
    smoke_fail "case 2: tmux session '$FAKE_TMUX_SESSION_2' did not come up"
  fi

  wait_for_pane_descendant "$FAKE_TMUX_SESSION_2" claude 25 || \
    smoke_fail "case 2: pane never reached the symlinked 'claude' command (comm not updated yet?)"

  SMOKE_AGENT_SESSION["live-agent"]="$FAKE_TMUX_SESSION_2"
  SMOKE_AGENT_ENGINE["live-agent"]="claude"

  if ! bridge_agent_engine_process_alive live-agent claude; then
    smoke_fail "case 2: expected rc=0 (claude in pane tree), got rc=1"
  fi
  # Strict basename match: a 'claude' descendant must NOT satisfy
  # engine=codex. This is what keeps the `activity_state="starting"`
  # branch from misfiring on agents whose engine kind drifted.
  if bridge_agent_engine_process_alive live-agent codex; then
    smoke_fail "case 2: 'claude' descendant must NOT match engine=codex"
  fi
}

main() {
  smoke_require_cmd tmux
  smoke_require_cmd python3

  smoke_make_temp_root "$SMOKE_NAME"
  source_bridge_tmux

  smoke_run "name predicate (unit-level)" case_name_predicate_unit
  smoke_run "no tmux session"             case_no_tmux_session
  smoke_run "tmux without engine"         case_tmux_without_engine
  smoke_run "tmux with fake engine"       case_tmux_with_fake_engine

  smoke_log "passed"
}

main "$@"
