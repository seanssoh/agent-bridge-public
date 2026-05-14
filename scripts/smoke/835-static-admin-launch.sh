#!/usr/bin/env bash
# scripts/smoke/835-static-admin-launch.sh — issue #835 Wave C closing smoke.
#
# Acceptance criterion 5 of issue #835: "Add a regression smoke that
# fails if a static admin startup hangs before spawning the engine."
#
# The original 2026-05-14 incident: operator's static admin `patch`
# tmux pane existed (running `bridge-run.sh patch --continue`) but no
# `claude` child ever spawned. Root cause: `bridge_agent_launch_cmd`
# wedged inside `heredoc_write` while reading an embedded Python
# heredoc body, on Homebrew Bash 5.3.9, when sourced via an absolute
# path from a static admin session. `agb status` displayed the agent
# as `working` because it only checked tmux session presence, not
# whether the engine child had actually launched.
#
# Fix waves landed pre-Wave-C:
#   Wave A  (PR #845) — extract 6 Python heredoc bodies from
#                       lib/bridge-state.sh::bridge_agent_launch_cmd
#                       descendants to real scripts/python-helpers/*.py.
#   Wave A' (PR #846) — extract the upstream `bridge_extract_development_channels_from_command`
#                       Python heredoc body from lib/bridge-agents.sh.
#   Wave B  (PR #847) — `bridge_agent_engine_process_alive` helper in
#                       lib/bridge-tmux.sh + status downstream branches in
#                       bridge-status.py, bridge-agent.sh, bridge-daemon.sh,
#                       lib/bridge-state.sh to render `starting / stalled
#                       before engine` when tmux is present but the engine
#                       child is absent.
#
# Wave C (this smoke) covers the two regression vectors closing #835:
#
#   Case 1 (bridge_agent_launch_cmd-returns-promptly):
#     Source bridge-lib.sh against a hermetic BRIDGE_HOME, register a
#     synthesized static claude admin agent (BRIDGE_ADMIN_AGENT_ID set
#     to it), and invoke `bridge_agent_launch_cmd <agent>`. Assert the
#     wall-clock elapsed time is < 2 seconds. Pre-Wave-A this would
#     hang indefinitely on macOS Bash 5.3.9 in the operator's
#     reproducer. The driver lives in
#     scripts/smoke/835-static-admin-launch-helpers/launch-cmd-driver.sh
#     (tracked file — not a heredoc-to-file body, footgun #11).
#
#   Case 2 (engine-alive=false on tmux-without-engine):
#     Synthesize a tmux session whose only descendant is a long-running
#     `sleep` (no `claude`/`codex`). Assert
#     `bridge_agent_engine_process_alive target claude` returns rc=1.
#     This is the negative branch that distinguishes Wave B's
#     `starting/stalled before engine` from a normally-working session.
#
#   Case 3 (engine-alive=true on tmux-with-claude-symlinked-child):
#     Synthesize a tmux session whose inner command is a `sleep` invoked
#     by basename `claude` (via a symlink). The process-tree walker
#     reads `ps -o comm=` (kernel-truthful), so a symlink-renamed sleep
#     reads as `claude`. Assert rc=0. Positive control — without this,
#     a future regression that always returns rc=1 would pass case 2
#     trivially and silently break the live "working" classification.
#
# Wave B's scripts/smoke/status-engine-detect.sh covers the engine-alive
# predicate at a finer-grained level (4 cases: unit-level basename match
# + no-tmux + tmux-without-engine + tmux-with-fake-engine). Wave C's
# cases 2/3 are an intentional regression layer at the issue #835
# integration boundary — they exercise the same helper through a
# different driver, so a future refactor that breaks Wave B's invariants
# fails here too.
#
# Hermetic — no live BRIDGE_HOME contact. Requires:
#   - Bash 4+ (Homebrew on macOS; re-exec stanza below mirrors
#     scripts/smoke/heredoc-regression.sh).
#   - tmux  (cases 2 + 3)
#   - python3 (Wave A helper invocation + monotonic-ish timing fallback
#     when BSD `date` lacks %N)
#
# Footgun #11 self-audit: this smoke and its helpers contain none of
# the five Bash-5.3.9-heredoc-write-class forms (python heredoc-stdin,
# heredoc-to-file with the redirect on the left, here-string into a
# command, here-string driven loop, source-from-stdin-via-here-string).
# All multi-line driver bodies live in tracked files under
# scripts/smoke/835-static-admin-launch-helpers/. (Forbidden pattern
# strings intentionally omitted from this comment so the self-audit
# grep recipe does not flag a textual mention as a real callsite.)

# Bash 4+ re-exec (mirrors scripts/smoke/status-engine-detect.sh).
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
  echo "[smoke:835-static-admin-launch] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="835-static-admin-launch"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HELPERS_DIR="$SCRIPT_DIR/835-static-admin-launch-helpers"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Tunable upper bound for case 1 (seconds). The 2026-05-14 wedge was
# unbounded (operator killed after several minutes). Even a cold-cache
# call through the full bridge-lib.sh source chain + Python helper
# invocation completes in well under 1s on a modern laptop; we leave
# generous headroom so this does not flake on shared CI runners.
LAUNCH_CMD_DEADLINE_SECONDS="${BRIDGE_SMOKE_LAUNCH_CMD_DEADLINE:-2}"

FAKE_TMUX_SESSION_NO_ENGINE=""
FAKE_TMUX_SESSION_WITH_ENGINE=""

cleanup() {
  if [[ -n "$FAKE_TMUX_SESSION_NO_ENGINE" ]]; then
    tmux kill-session -t "=${FAKE_TMUX_SESSION_NO_ENGINE}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$FAKE_TMUX_SESSION_WITH_ENGINE" ]]; then
    tmux kill-session -t "=${FAKE_TMUX_SESSION_WITH_ENGINE}" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Mirror of scripts/smoke/status-engine-detect.sh::wait_for_pane_descendant.
# Tmux returns from `new-session -d` before the inner command has fully
# exec'd, so a tight assertion can race. We poll the pane's process tree
# for up to 2.5s for a descendant whose `comm` basename matches.
wait_for_pane_descendant() {
  local session="$1"
  local needle="$2"
  local max_attempts="${3:-25}"
  local pane_pid
  local attempt
  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    pane_pid="$(tmux display-message -p -t "=${session}:" '#{pane_pid}' 2>/dev/null || true)"
    if [[ "$pane_pid" =~ ^[0-9]+$ ]]; then
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

case_launch_cmd_returns_promptly() {
  local roster_template="$HELPERS_DIR/static-admin-roster.sh"
  local driver="$HELPERS_DIR/launch-cmd-driver.sh"
  local agent_id="smoke-static-admin"
  local output=""
  local elapsed=""
  local launch_cmd=""

  [[ -f "$roster_template" ]] || smoke_fail "case 1: roster template missing: $roster_template"
  [[ -f "$driver" ]] || smoke_fail "case 1: driver missing: $driver"

  # Run the driver under `timeout` so that a true regression (wedged
  # heredoc_write) terminates this smoke deterministically rather than
  # hanging the suite. The deadline is generous (2x the assertion
  # window) so non-regression slowness is still asserted on, not killed.
  local timeout_seconds=$(( LAUNCH_CMD_DEADLINE_SECONDS * 5 + 10 ))
  local rc=0
  # Invoke the driver through the *running* bash ($BASH, which is the
  # Homebrew bash we re-exec'd into above). The system /usr/bin/bash on
  # macOS is 3.2 and chokes on `declare -g` in the engine-alive driver
  # and `BASH_SOURCE`-based absolute-path sourcing in the launch-cmd
  # driver — using $BASH keeps the child shell on the same modern
  # interpreter as the parent smoke.
  if command -v timeout >/dev/null 2>&1; then
    output="$(timeout --foreground "${timeout_seconds}s" \
      "$BASH" "$driver" "$SMOKE_REPO_ROOT" "$BRIDGE_HOME" "$roster_template" "$agent_id" 2>&1)" || rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    output="$(gtimeout --foreground "${timeout_seconds}s" \
      "$BASH" "$driver" "$SMOKE_REPO_ROOT" "$BRIDGE_HOME" "$roster_template" "$agent_id" 2>&1)" || rc=$?
  else
    # Neither timeout binary available — run direct. A regression would
    # hang the test runner; on most Linux/macOS dev hosts at least one
    # variant is present.
    output="$("$BASH" "$driver" "$SMOKE_REPO_ROOT" "$BRIDGE_HOME" "$roster_template" "$agent_id" 2>&1)" || rc=$?
  fi

  if (( rc == 124 )); then
    smoke_fail "case 1: bridge_agent_launch_cmd driver TIMED OUT after ${timeout_seconds}s — pre-Wave-A heredoc_write wedge would manifest exactly this way. Output so far: $output"
  fi
  if (( rc != 0 )); then
    smoke_fail "case 1: bridge_agent_launch_cmd driver exited rc=$rc. Output: $output"
  fi

  launch_cmd="$(smoke_shell_field LAUNCH_CMD "$output")"
  elapsed="$(smoke_shell_field ELAPSED_SECONDS "$output")"

  if [[ -z "$launch_cmd" ]]; then
    smoke_fail "case 1: driver did not emit LAUNCH_CMD line. Output: $output"
  fi
  if [[ -z "$elapsed" ]]; then
    smoke_fail "case 1: driver did not emit ELAPSED_SECONDS line. Output: $output"
  fi

  # Assert elapsed < deadline. Use awk to compare floats portably.
  local under_deadline
  under_deadline="$(awk -v e="$elapsed" -v d="$LAUNCH_CMD_DEADLINE_SECONDS" \
    'BEGIN{ if (e+0 < d+0) print "1"; else print "0" }')"
  if [[ "$under_deadline" != "1" ]]; then
    smoke_fail "case 1: bridge_agent_launch_cmd took ${elapsed}s (deadline: ${LAUNCH_CMD_DEADLINE_SECONDS}s) — possible heredoc_write regression. Rendered launch_cmd: $launch_cmd"
  fi

  # Sanity: the rendered launch command should at minimum mention `claude`
  # (the static branch returns the literal fallback when no channel
  # injection rewires happen on a fresh roster with no channel state).
  case "$launch_cmd" in
    *claude*) ;;
    *) smoke_fail "case 1: rendered launch_cmd missing 'claude': $launch_cmd" ;;
  esac

  smoke_log "case 1: bridge_agent_launch_cmd returned in ${elapsed}s (deadline ${LAUNCH_CMD_DEADLINE_SECONDS}s) — heredoc_write regression vector closed"
}

case_engine_alive_false_when_no_engine_child() {
  local driver="$HELPERS_DIR/engine-alive-driver.sh"
  [[ -f "$driver" ]] || smoke_fail "case 2: driver missing: $driver"

  FAKE_TMUX_SESSION_NO_ENGINE="agb-smoke-835-no-engine-$$-${RANDOM}"
  # Inner command is `bash -c 'exec sleep 30'` — `exec` so the pane PID
  # IS the sleep PID (no extra bash layer). No `claude`/`codex` anywhere
  # in the descendant tree — this is the operator's #835 wedge shape
  # (tmux pane exists running bridge-run.sh, but no engine child ever
  # spawned).
  tmux new-session -d -s "$FAKE_TMUX_SESSION_NO_ENGINE" \
    "bash -c 'exec sleep 30'"

  if ! tmux has-session -t "=${FAKE_TMUX_SESSION_NO_ENGINE}" 2>/dev/null; then
    smoke_fail "case 2: tmux session '$FAKE_TMUX_SESSION_NO_ENGINE' did not come up"
  fi

  wait_for_pane_descendant "$FAKE_TMUX_SESSION_NO_ENGINE" sleep 25 || \
    smoke_fail "case 2: pane never reached the inner 'sleep' command (comm not updated yet?)"

  local output rc
  output="$("$BASH" "$driver" "$SMOKE_REPO_ROOT" no-engine "$FAKE_TMUX_SESSION_NO_ENGINE" "" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if (( rc != 0 )); then
    smoke_fail "case 2: engine-alive driver exited rc=$rc. Output: $output"
  fi

  local engine_rc
  engine_rc="$(smoke_shell_field ENGINE_ALIVE_RC "$output")"
  if [[ "$engine_rc" != "1" ]]; then
    smoke_fail "case 2: expected engine_alive rc=1 (no claude in pane tree — 'stalled before engine'), got rc=$engine_rc. Driver output: $output"
  fi

  smoke_log "case 2: bridge_agent_engine_process_alive correctly reports rc=1 on tmux-without-engine — 'starting/stalled before engine' branch wired"
}

case_engine_alive_true_when_claude_symlinked_child() {
  local driver="$HELPERS_DIR/engine-alive-driver.sh"
  [[ -f "$driver" ]] || smoke_fail "case 3: driver missing: $driver"

  local fake_bin_dir="$SMOKE_TMP_ROOT/fake-bin-835"
  mkdir -p "$fake_bin_dir"
  ln -sf "$(command -v sleep)" "$fake_bin_dir/claude"

  FAKE_TMUX_SESSION_WITH_ENGINE="agb-smoke-835-with-engine-$$-${RANDOM}"
  # Symlink-renamed sleep: kernel `comm` reads as `claude`, satisfying
  # `bridge_tmux_command_name_matches_engine`. This keeps the smoke
  # hermetic — no real claude binary required.
  tmux new-session -d -s "$FAKE_TMUX_SESSION_WITH_ENGINE" \
    "bash -c 'exec \"$fake_bin_dir/claude\" 30'"

  if ! tmux has-session -t "=${FAKE_TMUX_SESSION_WITH_ENGINE}" 2>/dev/null; then
    smoke_fail "case 3: tmux session '$FAKE_TMUX_SESSION_WITH_ENGINE' did not come up"
  fi

  wait_for_pane_descendant "$FAKE_TMUX_SESSION_WITH_ENGINE" claude 25 || \
    smoke_fail "case 3: pane never reached the symlinked 'claude' command"

  local output rc
  output="$("$BASH" "$driver" "$SMOKE_REPO_ROOT" with-engine "$FAKE_TMUX_SESSION_WITH_ENGINE" "$fake_bin_dir" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if (( rc != 0 )); then
    smoke_fail "case 3: engine-alive driver exited rc=$rc. Output: $output"
  fi

  local engine_rc
  engine_rc="$(smoke_shell_field ENGINE_ALIVE_RC "$output")"
  if [[ "$engine_rc" != "0" ]]; then
    smoke_fail "case 3: expected engine_alive rc=0 (claude symlinked sleep in pane tree), got rc=$engine_rc. Driver output: $output"
  fi

  smoke_log "case 3: bridge_agent_engine_process_alive correctly reports rc=0 on tmux-with-claude-symlinked-child — positive control"
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd tmux
  smoke_require_cmd awk

  smoke_setup_bridge_home "835-static-admin-launch"

  smoke_run "case 1: bridge_agent_launch_cmd returns <${LAUNCH_CMD_DEADLINE_SECONDS}s on static claude admin" \
    case_launch_cmd_returns_promptly
  smoke_run "case 2: engine-alive=false on tmux-without-engine (stalled before engine)" \
    case_engine_alive_false_when_no_engine_child
  smoke_run "case 3: engine-alive=true on tmux-with-claude-symlinked-child (positive control)" \
    case_engine_alive_true_when_claude_symlinked_child

  smoke_log "passed"
}

main "$@"
