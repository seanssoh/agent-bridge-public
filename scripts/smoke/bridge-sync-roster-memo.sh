#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/bridge-sync-roster-memo.sh — Issue #848 r2 (codex Vector
# 2 + 6) regression fixture.
#
# Guards bridge-sync.sh's roster-cache invalidation contract from
# regressing. The Issue #848 r1 perf patch added per-process memoization
# to `bridge_load_roster` (BRIDGE_ROSTER_CACHE_LOADED flag in
# lib/bridge-state.sh). codex r1 review caught that bridge-sync.sh
# mutates the roster files (archive / remove / persist) but the
# second/third `bridge_load_roster` calls in `bridge_sync_main` were
# no-oping against the cache — so pruned dynamic agents lingered in
# BRIDGE_AGENT_* maps for the rest of the sync pass and the downstream
# `bridge_render_active_roster` reported them as still-active.
#
# r2 fix: prune_missing_dynamic_agents / refresh_missing_session_ids
# now call `bridge_roster_cache_invalidate` after their mutations, and
# `bridge_sync_main` has a defensive invalidate immediately before
# `bridge_render_active_roster`.
#
# Test plan:
#   T1. `prune_missing_dynamic_agents` flips
#       BRIDGE_ROSTER_CACHE_LOADED from 1 -> 0 when it prunes at least
#       one stale dynamic agent.
#   T2. `prune_missing_dynamic_agents` does NOT touch the flag when
#       there is nothing to prune (no churn => no invalidation).
#   T3. `refresh_missing_session_ids` flips the flag from 1 -> 0 when
#       it persists at least one agent state.
#   T4. `refresh_missing_session_ids` leaves the flag intact when no
#       agent needs a fresh session id (no churn => no invalidation).
#   T5. `bridge_sync_main` end-to-end: spawn 2 dynamic agents, archive
#       1, run sync, verify the rendered active-roster has 1 (not 2).
#
# Like scripts/smoke/dynamic-start-grace.sh, this fixture sources
# bridge-sync.sh directly and shadows the real bridge-state.sh helpers
# so we can drive the prune/refresh logic without a live tmux/queue
# stack. T5 stubs `bridge_render_active_roster` itself to capture which
# agents are visible at render time, since the real render path runs
# `bridge_queue_cli` (sqlite) + python3 helpers that pull in a much
# larger surface than this smoke needs to exercise.
#
# Footgun #11 (heredoc_write deadlock class): this fixture writes
# `printf '%s\n' >$tmp` only — no `python3 - <<'PY'`, no `cat <<EOF
# > $tmp` with multi-line bodies, no `<<<` here-strings. See
# `memory/feedback_bash_heredoc_write_class_recurrence.md`.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays. macOS ships /bin/bash
# 3.2 — match the recipe used by scripts/smoke/dynamic-start-grace.sh.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:bridge-sync-roster-memo] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="bridge-sync-roster-memo"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "bridge-sync-roster-memo"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-sync.sh"

if ! declare -F prune_missing_dynamic_agents >/dev/null; then
  smoke_fail "prune_missing_dynamic_agents not defined after sourcing bridge-sync.sh"
fi
if ! declare -F refresh_missing_session_ids >/dev/null; then
  smoke_fail "refresh_missing_session_ids not defined after sourcing bridge-sync.sh"
fi
if ! declare -F bridge_sync_main >/dev/null; then
  smoke_fail "bridge_sync_main not defined after sourcing bridge-sync.sh"
fi
if ! declare -F bridge_roster_cache_invalidate >/dev/null; then
  smoke_fail "bridge_roster_cache_invalidate not defined after sourcing bridge-sync.sh (lib/bridge-state.sh missing?)"
fi

# Stub state — same pattern as scripts/smoke/dynamic-start-grace.sh.
declare -g -A STUB_DYNAMIC_AGENTS=()
declare -g -A STUB_ACTIVE=()
declare -g -A STUB_ARCHIVED=()
declare -g -A STUB_REMOVED=()
declare -g -A STUB_PERSISTED=()
declare -g -A STUB_RENDER_SEEN=()

bridge_agent_is_active() {
  [[ -n "${STUB_ACTIVE[$1]+x}" ]]
}

bridge_dynamic_agent_ids() {
  local a
  for a in "${!STUB_DYNAMIC_AGENTS[@]}"; do
    printf '%s\n' "$a"
  done | sort
}

bridge_archive_dynamic_agent() {
  STUB_ARCHIVED[$1]=1
  return 0
}

bridge_remove_dynamic_agent_file() {
  STUB_REMOVED[$1]=1
  return 0
}

bridge_agent_clear_idle_marker() {
  return 0
}

bridge_agent_session_id() {
  printf '%s' "${BRIDGE_AGENT_SESSION_ID[$1]-}"
}

bridge_agent_engine() {
  printf 'codex'
}

bridge_agent_workdir() {
  printf '/tmp/smoke-workdir'
}

bridge_detect_session_id() {
  # signature: (engine, workdir, created_at, exclude_csv)
  # return a fixed synthetic id so refresh_missing_session_ids has
  # something to persist.
  printf 'session-id-%s\n' "$$"
}

bridge_resolve_resume_session_id() {
  # signature: (engine, agent, workdir, detected). pass through the
  # detected value so refresh_missing_session_ids proceeds to persist.
  printf '%s' "${4-}"
}

bridge_persist_agent_state() {
  STUB_PERSISTED[$1]=1
  return 0
}

bridge_reconcile_idle_markers() {
  return 0
}

bridge_render_active_roster() {
  # Capture which agents are visible at render time so T5 can assert
  # the pruned agent disappears from the rendered set.
  local agent
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if bridge_agent_is_active "$agent"; then
      STUB_RENDER_SEEN[$agent]=1
    fi
  done
}

bridge_warn() {
  printf '[warn] %s\n' "$*" >&2
}

# bridge_load_roster replacement that simulates a real reload by
# repopulating BRIDGE_AGENT_IDS from the live STUB_DYNAMIC_AGENTS set
# (minus anything we've already marked archived+removed). This lets T5
# detect whether `bridge_sync_main` actually re-reads the roster after
# pruning. When the cache flag is set, the memo no-op is preserved by
# the real implementation in lib/bridge-state.sh — but we replace it
# with a stub here so the smoke does not need a real roster file on
# disk. The stub honors the cache flag in the same way.
bridge_load_roster() {
  if [[ "${BRIDGE_ROSTER_CACHE_LOADED:-0}" == "1" ]]; then
    return 0
  fi
  # Repopulate BRIDGE_AGENT_IDS from STUB_DYNAMIC_AGENTS minus already-
  # pruned entries. Mirrors what the real lib/bridge-state.sh would do
  # after the dynamic .env files are removed.
  unset BRIDGE_AGENT_IDS
  declare -g -a BRIDGE_AGENT_IDS=()
  local a
  for a in "${!STUB_DYNAMIC_AGENTS[@]}"; do
    if [[ -n "${STUB_ARCHIVED[$a]+x}" && -n "${STUB_REMOVED[$a]+x}" ]]; then
      continue
    fi
    BRIDGE_AGENT_IDS+=("$a")
  done
  BRIDGE_ROSTER_CACHE_LOADED=1
}

declare -g -A BRIDGE_AGENT_CREATED_AT=()
declare -g -A BRIDGE_AGENT_SESSION_ID=()
declare -g -a BRIDGE_AGENT_IDS=()

reset_stubs() {
  unset STUB_DYNAMIC_AGENTS STUB_ACTIVE STUB_ARCHIVED STUB_REMOVED STUB_PERSISTED STUB_RENDER_SEEN
  unset BRIDGE_AGENT_CREATED_AT BRIDGE_AGENT_SESSION_ID BRIDGE_AGENT_IDS
  unset CLAIMED_SESSION_IDS PRUNED_DYNAMIC
  declare -g -A STUB_DYNAMIC_AGENTS=()
  declare -g -A STUB_ACTIVE=()
  declare -g -A STUB_ARCHIVED=()
  declare -g -A STUB_REMOVED=()
  declare -g -A STUB_PERSISTED=()
  declare -g -A STUB_RENDER_SEEN=()
  declare -g -A BRIDGE_AGENT_CREATED_AT=()
  declare -g -A BRIDGE_AGENT_SESSION_ID=()
  declare -g -a BRIDGE_AGENT_IDS=()
  declare -g -A CLAIMED_SESSION_IDS=()
  declare -g -A PRUNED_DYNAMIC=()
  BRIDGE_ROSTER_CACHE_LOADED=0
}

register_dynamic_agent() {
  local agent="$1"
  local created_at="$2"
  STUB_DYNAMIC_AGENTS["$agent"]=1
  BRIDGE_AGENT_CREATED_AT["$agent"]="$created_at"
}

# T1 — prune_missing_dynamic_agents invalidates cache when it prunes.
test_prune_invalidates_on_churn() {
  reset_stubs
  local now
  now="$(date +%s)"
  register_dynamic_agent "stale-prune" "$((now - 21600))"  # 6h ago, will prune
  # Seed roster maps then pre-set the cache as "loaded" so we can see
  # whether prune flips it back.
  BRIDGE_AGENT_IDS=(stale-prune)
  BRIDGE_ROSTER_CACHE_LOADED=1

  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  prune_missing_dynamic_agents

  smoke_assert_eq "1" "${STUB_ARCHIVED[stale-prune]-0}" \
    "T1 stale dynamic was archived"
  smoke_assert_eq "0" "${BRIDGE_ROSTER_CACHE_LOADED}" \
    "T1 cache flag invalidated after prune"
}

# T2 — prune_missing_dynamic_agents leaves cache intact when nothing
# to prune (no churn ⇒ no need to drop the cache).
test_prune_skips_invalidate_without_churn() {
  reset_stubs
  local now
  now="$(date +%s)"
  register_dynamic_agent "fresh-keep" "$((now - 60))"  # 60s ago, within grace
  STUB_ACTIVE[active-keep]=1  # active agent never pruned
  register_dynamic_agent "active-keep" "$((now - 21600))"

  BRIDGE_AGENT_IDS=(fresh-keep active-keep)
  BRIDGE_ROSTER_CACHE_LOADED=1

  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  prune_missing_dynamic_agents

  smoke_assert_eq "" "${STUB_ARCHIVED[fresh-keep]-}" \
    "T2 fresh dynamic NOT archived (within grace)"
  smoke_assert_eq "" "${STUB_ARCHIVED[active-keep]-}" \
    "T2 active dynamic NOT archived (live session)"
  smoke_assert_eq "1" "${BRIDGE_ROSTER_CACHE_LOADED}" \
    "T2 cache flag preserved when no prune happened"
}

# T3 — refresh_missing_session_ids invalidates cache when it persists.
test_refresh_invalidates_on_persist() {
  reset_stubs
  local now
  now="$(date +%s)"
  STUB_DYNAMIC_AGENTS[needs-session]=1
  STUB_ACTIVE[needs-session]=1
  BRIDGE_AGENT_CREATED_AT[needs-session]="$now"
  # Empty session_id triggers the detect+persist branch.
  BRIDGE_AGENT_SESSION_ID[needs-session]=""
  BRIDGE_AGENT_IDS=(needs-session)
  BRIDGE_ROSTER_CACHE_LOADED=1

  refresh_missing_session_ids

  smoke_assert_eq "1" "${STUB_PERSISTED[needs-session]-0}" \
    "T3 needs-session agent persisted"
  smoke_assert_eq "0" "${BRIDGE_ROSTER_CACHE_LOADED}" \
    "T3 cache flag invalidated after persist"
}

# T4 — refresh_missing_session_ids leaves cache intact when no agent
# needs a fresh session id (no churn ⇒ no need to drop the cache).
test_refresh_skips_invalidate_without_churn() {
  reset_stubs
  local now
  now="$(date +%s)"
  STUB_DYNAMIC_AGENTS[already-known]=1
  STUB_ACTIVE[already-known]=1
  BRIDGE_AGENT_CREATED_AT[already-known]="$now"
  # Non-empty session_id => refresh short-circuits without persisting.
  BRIDGE_AGENT_SESSION_ID[already-known]="already-known-session-xyz"
  BRIDGE_AGENT_IDS=(already-known)
  BRIDGE_ROSTER_CACHE_LOADED=1

  refresh_missing_session_ids

  smoke_assert_eq "" "${STUB_PERSISTED[already-known]-}" \
    "T4 already-known agent NOT re-persisted"
  smoke_assert_eq "1" "${BRIDGE_ROSTER_CACHE_LOADED}" \
    "T4 cache flag preserved when nothing was persisted"
}

# T5 — bridge_sync_main end-to-end: pruned agent does not appear in
# the rendered active roster. The regression vector is: r1 perf patch
# without invalidate ⇒ bridge_render_active_roster sees the stale
# BRIDGE_AGENT_IDS that still contains the pruned agent.
test_sync_main_render_excludes_pruned() {
  reset_stubs
  local now
  now="$(date +%s)"
  # Two dynamic agents — one active (kept), one stale (pruned).
  register_dynamic_agent "alpha-keep" "$((now - 21600))"  # 6h old
  STUB_ACTIVE[alpha-keep]=1  # has tmux ⇒ kept
  register_dynamic_agent "beta-prune" "$((now - 21600))"  # 6h old
  # beta-prune has no STUB_ACTIVE entry ⇒ pruned by sync.

  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  bridge_sync_main

  smoke_assert_eq "1" "${STUB_ARCHIVED[beta-prune]-0}" \
    "T5 stale agent (beta-prune) archived during sync"
  smoke_assert_eq "" "${STUB_ARCHIVED[alpha-keep]-}" \
    "T5 active agent (alpha-keep) NOT archived"
  smoke_assert_eq "1" "${STUB_RENDER_SEEN[alpha-keep]-0}" \
    "T5 active agent (alpha-keep) visible in rendered active roster"
  if [[ -n "${STUB_RENDER_SEEN[beta-prune]+x}" ]]; then
    smoke_fail "T5 pruned agent (beta-prune) leaked into rendered active roster — cache invalidation regression"
  fi
}

# T6 — Issue #848 codex r2 Vector 2: archive succeeds + remove fails
# must STILL invalidate the cache, because the archive write has already
# mutated the on-disk history env. Pre-r3 the flag was only flipped AFTER
# remove succeeded, so this path fell through `continue` with the cache
# left stale. Override `bridge_remove_dynamic_agent_file` to return 1 so
# we exercise the half-success branch deterministically.
test_prune_archive_ok_remove_fail_still_invalidates() {
  reset_stubs
  local now
  now="$(date +%s)"
  register_dynamic_agent "stale-half-fail" "$((now - 21600))"  # 6h ago
  BRIDGE_AGENT_IDS=(stale-half-fail)
  BRIDGE_ROSTER_CACHE_LOADED=1

  # Override the remove stub for this test only — archive still succeeds
  # via the existing stub at line 110.
  # shellcheck disable=SC2329  # invoked indirectly via prune_missing_dynamic_agents
  bridge_remove_dynamic_agent_file() {
    STUB_REMOVED[$1]=0
    return 1
  }

  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  prune_missing_dynamic_agents

  # Restore the default stub so subsequent tests see the success path.
  # shellcheck disable=SC2329  # invoked indirectly via prune_missing_dynamic_agents
  bridge_remove_dynamic_agent_file() {
    STUB_REMOVED[$1]=1
    return 0
  }

  smoke_assert_eq "1" "${STUB_ARCHIVED[stale-half-fail]-0}" \
    "T6 archive ran (history env mutated on disk)"
  smoke_assert_eq "0" "${STUB_REMOVED[stale-half-fail]-1}" \
    "T6 remove failed (simulated)"
  smoke_assert_eq "0" "${BRIDGE_ROSTER_CACHE_LOADED}" \
    "T6 cache flag invalidated even though remove failed (archive write alone is sufficient)"
}

smoke_run "T1 prune invalidates cache on churn"            test_prune_invalidates_on_churn
smoke_run "T2 prune leaves cache intact without churn"     test_prune_skips_invalidate_without_churn
smoke_run "T3 refresh invalidates cache on persist"        test_refresh_invalidates_on_persist
smoke_run "T4 refresh leaves cache intact without churn"   test_refresh_skips_invalidate_without_churn
smoke_run "T5 sync render excludes pruned dynamic"         test_sync_main_render_excludes_pruned
smoke_run "T6 prune archive-ok+remove-fail still invalidates" test_prune_archive_ok_remove_fail_still_invalidates

smoke_log "all checks passed"
