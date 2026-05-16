#!/usr/bin/env bash
# scripts/smoke/worktree-doctor-reap-zombies.sh — Track C of the 2026-05-16
# operator-audit wave.
#
# Guards `_bridge_worktree_doctor_reap_children` in lib/bridge-agents.sh.
# The doctor function `bridge_worktree_doctor` reaps stale fixer worktrees
# under .claude/worktrees/<agent-*|ab-*>, but BEFORE this fix it only
# pruned the directory + the git worktree metadata. Any daemonized child
# process that had been spawned from inside the worktree and reparented to
# init(1) was left running forever — Sean observed 7 such
# bridge-watchdog-silence.py processes on his Mac (2026-05-16), parented
# to pid 1, alive 8-12 days, with absolute argv pointing at worktree dirs
# that had been pruned long ago.
#
# This smoke exercises two zombie shapes and one false-positive guard:
#
#   Case 1 (direct-exec zombie): a `sleep` child renamed via a symlink so
#   its argv[0] is the absolute worktree path. The reap helper MUST
#   identify and terminate it.
#
#   Case 2 (interpreter-exec zombie): a `bash -c '...'` child whose argv
#   contains the worktree path as a script-argument token (mirrors the
#   exact shape of the observed `Python /path/to/worktree/foo.py run`
#   zombies — argv[0] is the interpreter, argv[1] is a worktree path
#   token). The reap helper MUST terminate it. This is the load-bearing
#   case: a naive "command starts with worktree path" anchor would MISS it.
#
#   Case 3 (control, false-positive guard): a `sleep` child whose argv
#   contains NO worktree path. The reap helper MUST leave it alive — the
#   match anchor must not bleed into unrelated processes.
#
# Footgun #11 self-audit: no <<EOF / <<'PY' heredoc-stdin captured into
# $(). All multi-line data crosses fd boundaries via `mktemp + < file` or
# direct `>>` append.

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
  echo "[smoke:worktree-doctor-reap-zombies] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="worktree-doctor-reap-zombies"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Track spawned helper PIDs so the cleanup trap always wipes them, even
# on assertion failure. The test itself asserts which ones should be dead
# vs alive — this is the belt-and-suspenders teardown.
SPAWNED_PIDS=()

cleanup() {
  local p
  for p in "${SPAWNED_PIDS[@]:-}"; do
    [[ -z "$p" ]] && continue
    kill -KILL "$p" 2>/dev/null || true
  done
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Load `_bridge_worktree_doctor_reap_children` out of bridge-agents.sh
# without pulling in the upstream module graph. The function and its
# dependencies (none, beyond `ps`, `kill`, `sleep`, `printf`) are
# self-contained, mirroring the slice-and-source pattern in
# scripts/smoke/worktree-doctor.sh.
load_reap_fn() {
  local agents_sh="$SMOKE_REPO_ROOT/lib/bridge-agents.sh"
  smoke_assert_file_exists "$agents_sh" "bridge-agents.sh source"

  local snippet="$SMOKE_TMP_ROOT/reap.sh"
  awk '
    /^bridge_static_agents_for_project_engine\(\)/ { in_block=0 }
    in_block { print }
    /^_bridge_worktree_doctor_reap_children\(\)/ { in_block=1; print }
  ' "$agents_sh" >"$snippet"
  smoke_assert_file_exists "$snippet" "reap snippet"

  # shellcheck source=/dev/null
  source "$snippet"
  if ! declare -F _bridge_worktree_doctor_reap_children >/dev/null; then
    smoke_fail "_bridge_worktree_doctor_reap_children not defined after sourcing snippet"
  fi
}

# Wait for a PID to disappear, up to timeout_secs. Returns 0 if dead, 1 if
# still alive. Polls every 100ms.
wait_for_pid_death() {
  local pid="$1"
  local timeout_secs="${2:-5}"
  local deadline_iters=$(( timeout_secs * 10 ))
  local i
  for (( i = 0; i < deadline_iters; i++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

case_reap_direct_exec_and_interpreter_exec_but_not_control() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  load_reap_fn

  local wt_path="$SMOKE_TMP_ROOT/.claude/worktrees/agent-fakezombie"
  mkdir -p "$wt_path"

  # --- Case 1 setup: direct-exec zombie. Symlink `sleep` into the
  # worktree under a deterministic name. When exec'd, argv[0] will be the
  # symlink's absolute path — which starts with "<wt_path>/" — satisfying
  # the anchor.
  local sleep_bin
  sleep_bin="$(command -v sleep)" || smoke_fail "sleep binary not found on PATH"
  ln -s "$sleep_bin" "$wt_path/zombie-direct"
  "$wt_path/zombie-direct" 600 &
  local direct_pid=$!
  SPAWNED_PIDS+=("$direct_pid")

  # --- Case 2 setup: interpreter-exec zombie. argv looks like
  # `bash <wt_path>/zombie-script.sh`. argv[0] is the interpreter (no
  # worktree prefix), argv[1] is the worktree path — exactly the operator
  # observation shape (Python + script-path). NOTE: the inner script must
  # NOT `exec` into another binary — that would replace the interpreter
  # and clear the script-path token from argv, defeating the test.
  cat >"$wt_path/zombie-script.sh" <<'INNER'
#!/usr/bin/env bash
# Propagate signals to the child sleep so the test fixture doesn't leak
# orphaned sleeps after SIGTERM lands on the parent bash.
trap 'kill -TERM "$child_pid" 2>/dev/null; wait "$child_pid" 2>/dev/null; exit 0' TERM INT
sleep 600 &
child_pid=$!
wait "$child_pid"
INNER
  chmod +x "$wt_path/zombie-script.sh"
  bash "$wt_path/zombie-script.sh" &
  local interp_pid=$!
  SPAWNED_PIDS+=("$interp_pid")

  # --- Case 3 setup: control sleep, no worktree path in its argv.
  sleep 600 &
  local control_pid=$!
  SPAWNED_PIDS+=("$control_pid")

  # Give the kernel a beat to set up exec for all three.
  sleep 0.3

  # Sanity: all three are alive before we run the reaper.
  for p in "$direct_pid" "$interp_pid" "$control_pid"; do
    if ! kill -0 "$p" 2>/dev/null; then
      smoke_fail "test fixture broken: pid $p exited before reap ran"
    fi
  done

  # --- Dry-run first: must list both zombie PIDs and NOT kill anything.
  local dry_out
  dry_out="$(_bridge_worktree_doctor_reap_children "$wt_path" "dry-run" 2>&1)"
  smoke_assert_contains "$dry_out" "would reap" "dry-run announces reap intent"
  smoke_assert_contains "$dry_out" "$direct_pid" "dry-run lists direct-exec PID"
  smoke_assert_contains "$dry_out" "$interp_pid" "dry-run lists interpreter-exec PID"
  smoke_assert_not_contains "$dry_out" "$control_pid" "dry-run does NOT list control PID"

  # Dry-run must not actually have killed them.
  if ! kill -0 "$direct_pid" 2>/dev/null; then
    smoke_fail "dry-run wrongly killed direct-exec PID $direct_pid"
  fi
  if ! kill -0 "$interp_pid" 2>/dev/null; then
    smoke_fail "dry-run wrongly killed interpreter-exec PID $interp_pid"
  fi
  if ! kill -0 "$control_pid" 2>/dev/null; then
    smoke_fail "dry-run wrongly killed control PID $control_pid"
  fi

  # --- Apply: zombies must die within 5s, control must survive.
  local apply_out
  apply_out="$(_bridge_worktree_doctor_reap_children "$wt_path" "apply" 2>&1)"
  smoke_assert_contains "$apply_out" "sent SIGTERM" "apply announces SIGTERM"
  smoke_assert_contains "$apply_out" "$direct_pid" "apply targets direct-exec PID"
  smoke_assert_contains "$apply_out" "$interp_pid" "apply targets interpreter-exec PID"
  smoke_assert_not_contains "$apply_out" "$control_pid" "apply does NOT target control PID"

  if ! wait_for_pid_death "$direct_pid" 5; then
    smoke_fail "direct-exec zombie pid $direct_pid still alive after apply + 5s"
  fi
  if ! wait_for_pid_death "$interp_pid" 5; then
    smoke_fail "interpreter-exec zombie pid $interp_pid still alive after apply + 5s"
  fi

  if ! kill -0 "$control_pid" 2>/dev/null; then
    smoke_fail "control sleep pid $control_pid was killed (false positive)"
  fi
}

# Anchor edge-case: a sibling worktree whose name shares a prefix with the
# target must NOT be touched. e.g. ".../agent-foo/" reaper must leave
# ".../agent-foo-bar/" processes alone. This is the "trailing slash on
# the anchor" assertion — drop the trailing slash from the implementation
# and this case fails.
case_anchor_does_not_bleed_into_sibling_prefix() {
  smoke_setup_bridge_home "$SMOKE_NAME-anchor"
  load_reap_fn

  local target_wt="$SMOKE_TMP_ROOT/.claude/worktrees/agent-foo"
  local sibling_wt="$SMOKE_TMP_ROOT/.claude/worktrees/agent-foo-bar"
  mkdir -p "$target_wt" "$sibling_wt"

  local sleep_bin
  sleep_bin="$(command -v sleep)"
  # Zombie under the SIBLING (longer-named) worktree — must NOT be reaped
  # when we run the reaper on the SHORTER target.
  ln -s "$sleep_bin" "$sibling_wt/zombie-sibling"
  "$sibling_wt/zombie-sibling" 600 &
  local sibling_pid=$!
  SPAWNED_PIDS+=("$sibling_pid")

  # Real zombie under the target.
  ln -s "$sleep_bin" "$target_wt/zombie-target"
  "$target_wt/zombie-target" 600 &
  local target_pid=$!
  SPAWNED_PIDS+=("$target_pid")

  sleep 0.3

  local apply_out
  apply_out="$(_bridge_worktree_doctor_reap_children "$target_wt" "apply" 2>&1)"
  smoke_assert_contains "$apply_out" "$target_pid" "apply targets the target-worktree PID"
  smoke_assert_not_contains "$apply_out" "$sibling_pid" \
    "apply does NOT target sibling worktree PID (prefix-trap guard)"

  if ! wait_for_pid_death "$target_pid" 5; then
    smoke_fail "target zombie pid $target_pid still alive after apply + 5s"
  fi
  if ! kill -0 "$sibling_pid" 2>/dev/null; then
    smoke_fail "sibling-prefix zombie pid $sibling_pid was killed (anchor leaked across worktree boundary)"
  fi
}

smoke_log "starting smoke: $SMOKE_NAME"
smoke_run "direct + interpreter zombies reaped, control survives" \
  case_reap_direct_exec_and_interpreter_exec_but_not_control
smoke_run "anchor does not bleed into sibling-prefix worktree" \
  case_anchor_does_not_bleed_into_sibling_prefix
smoke_log "all worktree-doctor-reap-zombies cases passed"
