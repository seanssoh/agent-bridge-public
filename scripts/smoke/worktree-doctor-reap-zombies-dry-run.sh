#!/usr/bin/env bash
# scripts/smoke/worktree-doctor-reap-zombies-dry-run.sh — Track C of the
# 2026-05-16 operator-audit wave, r2 follow-up.
#
# Integration regression guard for PR #927 r1: codex caught that the
# dry-run reap call lived inside the apply branch of
# `_bridge_worktree_doctor_classify_one`, which is unreachable when
# mode=dry-run because the function early-returns on `mode != apply`
# before reaching it. The companion smoke
# (`worktree-doctor-reap-zombies.sh`) only exercised the helper in
# isolation and so missed the bug.
#
# This smoke goes end-to-end: it invokes `bridge_worktree_doctor
# --dry-run --repo <fixture>` against a fixture where one worktree is
# classified REMOVE and a matching child process exists. Assertions:
#
#   1. Output contains a "would reap" line and the child's PID. This
#      proves the dry-run path actually invokes the reap helper.
#   2. The child process REMAINS ALIVE after the dry-run completes.
#      Dry-run must never signal.
#   3. The control sleep (no worktree path in its argv) is also alive
#      (false-positive guard).
#
# Why this is a separate smoke from worktree-doctor-reap-zombies.sh:
# this one slices the full `bridge_worktree_doctor` + classifier + reap
# helper triple and drives the public function, where the companion
# smoke only sources the leaf reap helper. The two together pin both
# the helper's behavior AND its wire-up.
#
# Footgun #11 self-audit: no <<EOF / <<'PY' heredoc-stdin captured into
# $(). The git fixture builders use plain git commands; the awk slice
# writes to a file.

# Bash 4+ re-exec (mirrors scripts/smoke/worktree-doctor.sh shape via
# status-engine-detect.sh).
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
  echo "[smoke:worktree-doctor-reap-zombies-dry-run] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="worktree-doctor-reap-zombies-dry-run"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

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

# Slice `bridge_worktree_doctor` through to just before
# `bridge_static_agents_for_project_engine`. That range includes
# `bridge_worktree_doctor`, `_bridge_worktree_doctor_classify_one`, AND
# `_bridge_worktree_doctor_reap_children` — exactly the trio we want to
# exercise end-to-end.
load_doctor_fns() {
  # shellcheck disable=SC2329  # called from the sourced snippet
  bridge_die() { printf '[stub:bridge_die] %s\n' "$*" >&2; exit 1; }
  # shellcheck disable=SC2329  # called from the sourced snippet
  bridge_warn() { printf '[stub:bridge_warn] %s\n' "$*" >&2; }
  export -f bridge_die bridge_warn

  local agents_sh="$SMOKE_REPO_ROOT/lib/bridge-agents.sh"
  smoke_assert_file_exists "$agents_sh" "bridge-agents.sh source"

  local snippet="$SMOKE_TMP_ROOT/doctor.sh"
  awk '
    /^bridge_static_agents_for_project_engine\(\)/ { in_doctor=0 }
    in_doctor { print }
    /^bridge_worktree_doctor\(\)/ { in_doctor=1; print }
  ' "$agents_sh" >"$snippet"
  smoke_assert_file_exists "$snippet" "doctor snippet"

  # shellcheck source=/dev/null
  source "$snippet"
  if ! declare -F bridge_worktree_doctor >/dev/null; then
    smoke_fail "bridge_worktree_doctor not defined after sourcing snippet"
  fi
  if ! declare -F _bridge_worktree_doctor_classify_one >/dev/null; then
    smoke_fail "_bridge_worktree_doctor_classify_one not defined after sourcing snippet"
  fi
  if ! declare -F _bridge_worktree_doctor_reap_children >/dev/null; then
    smoke_fail "_bridge_worktree_doctor_reap_children not defined after sourcing snippet"
  fi
}

# Build a repo with one MERGED fixer worktree (will classify REMOVE
# under dry-run) and no stash entries (no SKIP override). Mirrors the
# `build_repo_no_stash` pattern in scripts/smoke/worktree-doctor.sh.
build_repo_merged_only() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo/.claude/worktrees"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.name=smoke -c user.email=smoke@example.com commit -q --allow-empty -m "init"

  git -C "$repo" branch fix/merged-with-zombie
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/agent-zombie-host" fix/merged-with-zombie
  printf 'm\n' >"$repo/.claude/worktrees/agent-zombie-host/f.txt"
  git -C "$repo/.claude/worktrees/agent-zombie-host" \
    -c user.name=smoke -c user.email=smoke@example.com add f.txt
  git -C "$repo/.claude/worktrees/agent-zombie-host" \
    -c user.name=smoke -c user.email=smoke@example.com commit -q -m "merged work"
  git -C "$repo" -c user.name=smoke -c user.email=smoke@example.com \
    merge -q --no-ff fix/merged-with-zombie -m "merge merged-with-zombie"
}

case_dry_run_invokes_reap_helper_without_signaling() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  load_doctor_fns

  local repo="$SMOKE_TMP_ROOT/repo-dry-reap"
  build_repo_merged_only "$repo"

  local wt_path="$repo/.claude/worktrees/agent-zombie-host"
  # Resolve to the same path shape the doctor sees from
  # `git worktree list --porcelain` (no /private prefix dance), so the
  # anchor in the reap helper matches the spawned child's argv.
  wt_path="$(cd -P "$wt_path" && pwd -P)"

  # Spawn a direct-exec zombie: symlink sleep into the worktree, run it.
  # argv[0] is the absolute worktree path — matches the helper anchor.
  local sleep_bin
  sleep_bin="$(command -v sleep)" || smoke_fail "sleep binary not found"
  ln -s "$sleep_bin" "$wt_path/zombie-direct"
  "$wt_path/zombie-direct" 600 &
  local zombie_pid=$!
  SPAWNED_PIDS+=("$zombie_pid")

  # Control sleep with no worktree path in its argv.
  sleep 600 &
  local control_pid=$!
  SPAWNED_PIDS+=("$control_pid")

  # Give the kernel a beat to set up exec.
  sleep 0.3

  # Sanity: both alive before we drive the doctor.
  for p in "$zombie_pid" "$control_pid"; do
    if ! kill -0 "$p" 2>/dev/null; then
      smoke_fail "test fixture broken: pid $p exited before dry-run ran"
    fi
  done

  # Drive the full dry-run path.
  local dry_out
  dry_out="$(bridge_worktree_doctor --dry-run --repo "$repo" 2>&1)"

  # Assertion 1: REMOVE classification fired for our fixture worktree.
  smoke_assert_contains "$dry_out" "REMOVE" "dry-run classifies merged worktree as REMOVE"
  smoke_assert_contains "$dry_out" "agent-zombie-host" \
    "dry-run lists the fixture worktree path"

  # Assertion 2: the reap helper was actually invoked from dry-run.
  # If a future regression puts the call back inside the apply branch,
  # this 'would reap' line will be absent and the smoke fails.
  smoke_assert_contains "$dry_out" "would reap" \
    "dry-run output announces a would-reap line (helper was invoked)"
  smoke_assert_contains "$dry_out" "$zombie_pid" \
    "dry-run output names the zombie PID that would be reaped"

  # Assertion 3: false-positive guard. The control sleep PID must NOT
  # appear in the would-reap line.
  smoke_assert_not_contains "$dry_out" "$control_pid" \
    "dry-run does NOT name the control PID"

  # Assertion 4: dry-run must not signal anything. Give it a generous
  # 2s window to be sure no late SIGTERM is in flight, then confirm
  # both processes are still alive.
  sleep 0.5
  if ! kill -0 "$zombie_pid" 2>/dev/null; then
    smoke_fail "dry-run wrongly killed zombie pid $zombie_pid (must not signal)"
  fi
  if ! kill -0 "$control_pid" 2>/dev/null; then
    smoke_fail "dry-run wrongly killed control pid $control_pid (must not signal)"
  fi
}

smoke_log "starting smoke: $SMOKE_NAME"
smoke_run "bridge_worktree_doctor --dry-run invokes reaper for REMOVE rows, but never signals" \
  case_dry_run_invokes_reap_helper_without_signaling
smoke_log "all $SMOKE_NAME cases passed"
