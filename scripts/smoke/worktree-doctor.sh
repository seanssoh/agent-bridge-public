#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="worktree-doctor"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# This smoke exercises `bridge_worktree_doctor` as a function rather than
# through the full `agent-bridge worktree doctor` CLI:
#
#   - The CLI dispatcher pulls in bridge-lib.sh which fires the v0.8.0
#     isolation-v2 layout resolver. That requires either a BRIDGE_LAYOUT=v2
#     marker on disk or env overrides — environment fragile for a CI smoke.
#   - The doctor function is self-contained and only depends on `git`,
#     `bridge_die`, `bridge_warn`, `printf`, `cat`, `date`, `wc`, `tr` —
#     all available without the full bridge runtime.
#
# We slice `bridge_worktree_doctor` + `_bridge_worktree_doctor_classify_one`
# out of lib/bridge-agents.sh via awk and source the snippet alone, with a
# small `bridge_die` shim so we don't pull in the upstream module graph.
#
# Three cases (per the brief):
#   1. merged + unmerged + no stash → REMOVE for merged, KEEP for unmerged
#   2. apply only removes REMOVE rows, leaves KEEP rows
#   3. stash entry anywhere in the repo → ALL worktrees SKIP'd (conservative
#      safety: refs/stash is shared across worktrees so any stash anywhere
#      is treated as fail-safe — refuse to remove)

load_doctor_fns() {
  # Minimal stubs the doctor function calls.
  # shellcheck disable=SC2329  # called indirectly from the sourced snippet
  bridge_die() { printf '[stub:bridge_die] %s\n' "$*" >&2; exit 1; }
  # shellcheck disable=SC2329  # called indirectly from the sourced snippet
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
}

# Build a clean repo with merged + unmerged worktrees but no stash.
build_repo_no_stash() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo/.claude/worktrees"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.name=smoke -c user.email=smoke@example.com commit -q --allow-empty -m "init"

  # 1) Merged branch → expect REMOVE.
  git -C "$repo" branch fix/merged-track-a
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/agent-merged" fix/merged-track-a
  printf 'merged change\n' >"$repo/.claude/worktrees/agent-merged/file.txt"
  git -C "$repo/.claude/worktrees/agent-merged" \
    -c user.name=smoke -c user.email=smoke@example.com add file.txt
  git -C "$repo/.claude/worktrees/agent-merged" \
    -c user.name=smoke -c user.email=smoke@example.com commit -q -m "merged work"
  git -C "$repo" -c user.name=smoke -c user.email=smoke@example.com \
    merge -q --no-ff fix/merged-track-a -m "merge fix/merged"

  # 2) Unmerged branch, recent commit → expect KEEP.
  git -C "$repo" branch fix/unmerged-track-b
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/agent-unmerged" fix/unmerged-track-b
  printf 'unmerged WIP\n' >"$repo/.claude/worktrees/agent-unmerged/wip.txt"
  git -C "$repo/.claude/worktrees/agent-unmerged" \
    -c user.name=smoke -c user.email=smoke@example.com add wip.txt
  git -C "$repo/.claude/worktrees/agent-unmerged" \
    -c user.name=smoke -c user.email=smoke@example.com commit -q -m "wip"
}

# Build a repo with two worktrees (one merged) plus a third worktree that
# holds a stash entry. Because refs/stash is shared across worktrees, the
# stash will be visible from EVERY worktree's perspective — the doctor must
# refuse to remove any of them. This is the documented conservative policy
# in the brief: "Refuse to clean if stash present."
build_repo_with_stash() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo/.claude/worktrees"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.name=smoke -c user.email=smoke@example.com commit -q --allow-empty -m "init"

  git -C "$repo" branch fix/merged
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/agent-merged" fix/merged
  printf 'm\n' >"$repo/.claude/worktrees/agent-merged/m.txt"
  git -C "$repo/.claude/worktrees/agent-merged" \
    -c user.name=smoke -c user.email=smoke@example.com add m.txt
  git -C "$repo/.claude/worktrees/agent-merged" \
    -c user.name=smoke -c user.email=smoke@example.com commit -q -m "merged"
  git -C "$repo" -c user.name=smoke -c user.email=smoke@example.com \
    merge -q --no-ff fix/merged -m "merge"

  # Stash-holding worktree. Commit a baseline file so the worktree is
  # non-empty after we stash the WIP file; otherwise the post-stash
  # assertion that the stash worktree dir survives would be fragile.
  git -C "$repo" branch fix/stash
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/agent-stash" fix/stash
  printf 'baseline\n' >"$repo/.claude/worktrees/agent-stash/keep.txt"
  git -C "$repo/.claude/worktrees/agent-stash" \
    -c user.name=smoke -c user.email=smoke@example.com add keep.txt
  git -C "$repo/.claude/worktrees/agent-stash" \
    -c user.name=smoke -c user.email=smoke@example.com commit -q -m "baseline"
  # WIP that we will stash.
  printf 'unsaved local diff\n' >"$repo/.claude/worktrees/agent-stash/wip.txt"
  git -C "$repo/.claude/worktrees/agent-stash" \
    -c user.name=smoke -c user.email=smoke@example.com add wip.txt
  git -C "$repo/.claude/worktrees/agent-stash" \
    -c user.name=smoke -c user.email=smoke@example.com \
    stash push -q -m "smoke-stash" -- wip.txt

  # Sanity — stash should now be visible from any worktree's perspective.
  local stash_seen
  stash_seen="$(git -C "$repo/.claude/worktrees/agent-stash" stash list | wc -l | tr -d ' ')"
  smoke_assert_eq "1" "$stash_seen" "stash setup recorded one entry"
}

case_dry_run_classification() {
  smoke_setup_bridge_home "$SMOKE_NAME-dry"
  load_doctor_fns
  local repo="$SMOKE_TMP_ROOT/repo-dry"
  build_repo_no_stash "$repo"

  local out
  out="$(bridge_worktree_doctor --dry-run --repo "$repo" 2>&1)"

  smoke_assert_contains "$out" "REMOVE" "dry-run reports REMOVE row"
  smoke_assert_contains "$out" "KEEP" "dry-run reports KEEP row"
  smoke_assert_contains "$out" "agent-merged" "dry-run lists merged worktree"
  smoke_assert_contains "$out" "agent-unmerged" "dry-run lists unmerged worktree"

  # The agent-merged row should be REMOVE, the agent-unmerged row KEEP.
  local merged_row unmerged_row
  merged_row="$(printf '%s\n' "$out" | grep agent-merged || true)"
  unmerged_row="$(printf '%s\n' "$out" | grep agent-unmerged || true)"
  smoke_assert_contains "$merged_row" "REMOVE" "agent-merged classified REMOVE"
  smoke_assert_contains "$unmerged_row" "KEEP" "agent-unmerged classified KEEP"

  # No filesystem mutation in dry-run.
  smoke_assert_file_exists \
    "$repo/.claude/worktrees/agent-merged/file.txt" \
    "dry-run did not delete merged worktree"
  smoke_assert_file_exists \
    "$repo/.claude/worktrees/agent-unmerged/wip.txt" \
    "dry-run did not delete unmerged worktree"
}

case_apply_reaps_merged_only() {
  smoke_setup_bridge_home "$SMOKE_NAME-apply"
  load_doctor_fns
  local repo="$SMOKE_TMP_ROOT/repo-apply"
  build_repo_no_stash "$repo"

  local out
  out="$(bridge_worktree_doctor --apply --repo "$repo" 2>&1)"

  smoke_assert_contains "$out" "removed: $repo/.claude/worktrees/agent-merged" \
    "apply removes merged worktree"
  smoke_assert_not_contains "$out" "removed: $repo/.claude/worktrees/agent-unmerged" \
    "apply does NOT remove unmerged worktree"

  if [[ -d "$repo/.claude/worktrees/agent-merged" ]]; then
    smoke_fail "merged worktree dir should be gone after --apply"
  fi
  smoke_assert_file_exists \
    "$repo/.claude/worktrees/agent-unmerged/wip.txt" \
    "unmerged worktree retained after --apply"

  local porcelain
  porcelain="$(git -C "$repo" worktree list --porcelain)"
  smoke_assert_not_contains "$porcelain" "agent-merged" \
    "git no longer tracks the removed worktree"
  smoke_assert_contains "$porcelain" "agent-unmerged" \
    "git still tracks unmerged worktree"
}

case_stash_skip_all() {
  smoke_setup_bridge_home "$SMOKE_NAME-stash"
  load_doctor_fns
  local repo="$SMOKE_TMP_ROOT/repo-stash"
  build_repo_with_stash "$repo"

  # Dry run first: every worktree should classify SKIP because the shared
  # refs/stash makes the stash entry visible everywhere. This is the safe
  # behavior — the brief explicitly says "Refuse to clean if stash present."
  local dry_out
  dry_out="$(bridge_worktree_doctor --dry-run --repo "$repo" 2>&1)"
  smoke_assert_contains "$dry_out" "SKIP" "dry-run reports at least one SKIP row"
  # Match data rows (which start with the STATUS column) — not the summary
  # block (which prefixes labels with `  REMOVE     : <count>`). A data row
  # starts at column 1 with the STATUS keyword followed by ` | `.
  local data_rows
  data_rows="$(printf '%s\n' "$dry_out" | grep '^[A-Z]\+[[:space:]]*|' || true)"
  smoke_assert_not_contains "$data_rows" "REMOVE" \
    "no data row should be REMOVE while stash present"

  local merged_row stash_row
  merged_row="$(printf '%s\n' "$dry_out" | grep agent-merged || true)"
  stash_row="$(printf '%s\n' "$dry_out" | grep agent-stash || true)"
  smoke_assert_contains "$merged_row" "SKIP" "agent-merged SKIP'd due to shared stash"
  smoke_assert_contains "$stash_row"  "SKIP" "agent-stash SKIP'd"
  # Both rows should show non-zero stash count.
  if [[ ! "$merged_row" =~ \|[[:space:]]+[1-9] ]]; then
    smoke_fail "agent-merged row should show non-zero stash count: $merged_row"
  fi
  if [[ ! "$stash_row" =~ \|[[:space:]]+[1-9] ]]; then
    smoke_fail "agent-stash row should show non-zero stash count: $stash_row"
  fi

  # Apply: nothing should be removed because every row is SKIP.
  local apply_out
  apply_out="$(bridge_worktree_doctor --apply --repo "$repo" 2>&1)"
  smoke_assert_not_contains "$apply_out" "removed: " \
    "apply does not remove anything when stash is present"
  smoke_assert_file_exists \
    "$repo/.claude/worktrees/agent-merged/m.txt" \
    "merged worktree retained when stash present (safety)"
  smoke_assert_file_exists \
    "$repo/.claude/worktrees/agent-stash/keep.txt" \
    "stash worktree retained when stash present"
}

smoke_log "starting smoke: $SMOKE_NAME"
smoke_run "dry-run classification (merged → REMOVE, unmerged → KEEP)" case_dry_run_classification
smoke_run "apply removes only merged, leaves unmerged"               case_apply_reaps_merged_only
smoke_run "stash anywhere → all worktrees SKIP (apply is a no-op)"   case_stash_skip_all
smoke_log "all worktree-doctor cases passed"
