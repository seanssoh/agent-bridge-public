#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/dynamic-start-grace.sh — Issue #826 regression fixture.
#
# Guards bridge-sync.sh's dynamic-prune grace from regressing back to the
# hard-coded 15s window that lost the operator's first-start `crm-test`
# dynamic .env on 2026-05-14 (slow startup due to #815 heredoc stalls).
#
#   T1. Pure grace resolver: defaults to 300s when the env var is unset
#       or malformed; honors integer overrides.
#   T2. A 60s-old dynamic agent with NO tmux session survives the default
#       300s grace (the regression vector from the live recovery).
#   T3. A 6h-old dynamic agent with NO tmux session is STILL pruned (the
#       grace must not regress to "never prune").
#   T4. Operator override: BRIDGE_DYNAMIC_START_GRACE_SECONDS=120 prunes a
#       180s-old dynamic agent that would have survived the 300s default.
#
# This fixture sources bridge-sync.sh and calls
# `prune_missing_dynamic_agents` directly against stubbed dependency
# helpers (bridge_agent_is_active, bridge_dynamic_agent_ids,
# bridge_archive_dynamic_agent, bridge_remove_dynamic_agent_file,
# bridge_agent_clear_idle_marker, bridge_agent_session_id, bridge_warn).
# Driving the full bridge_load_roster / reconcile / render pipeline is
# not viable on macOS Bash 5.3.9 because several downstream helpers
# (bridge_resolve_resume_session_id, bridge_render_active_roster) use
# `python3 - <<'PY'` heredoc-stdin — the Footgun #11 deadlock class
# (#815). That deadlock is independent of #826's grace fix and out of
# scope for Wave A; this fixture's stubbed surface keeps the grace
# logic verifiable today without waiting on the #815 wave to land.
#
# Footgun-11 self-audit: this fixture writes its dynamic .env contents
# and stub state via `mktemp + printf '%s\n' > $tmp` (no heredoc-to-
# file, no here-string, no `python3 - <<'PY'`). The 2026-05-14 update
# to feedback_bash_heredoc_write_class_recurrence noted that even
# heredoc-to-file with a multi-line body recurs on Bash 5.3.9 — only
# the `printf > $tmp` + atomic `mv` recipe is safe.

set -euo pipefail

# This smoke uses associative arrays (declare -A) at top level which
# need Bash 4+. macOS ships /bin/bash 3.2 — re-exec into a Bash 4+
# candidate if necessary, mirroring the bridge-lib.sh recipe.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:dynamic-start-grace] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="dynamic-start-grace"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "dynamic-start-grace"

REPO_ROOT="$SMOKE_REPO_ROOT"

# --------------------------------------------------------------------------
# Source bridge-sync.sh so we get the real functions under test.
#
# bridge-sync.sh's top-level only runs `bridge_sync_main` when executed
# as a script (BASH_SOURCE[0] == $0 guard); sourcing it gives us the
# function definitions without driving the full pipeline. Sourcing
# bridge-sync.sh also brings in bridge-lib.sh + the whole lib/ tree
# (bridge-state.sh, bridge-agents.sh, etc.) — that's fine; our stubs
# below intentionally re-define the few helpers `prune_missing_dynamic_agents`
# calls so the smoke does not need a live roster/tmux/queue.
# --------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-sync.sh"

# Sanity guard: confirm we got the right grace function from the file
# under test rather than a stale shell scope.
if ! declare -F resolve_dynamic_start_grace_seconds >/dev/null; then
  smoke_fail "resolve_dynamic_start_grace_seconds not defined after sourcing bridge-sync.sh"
fi
if ! declare -F prune_missing_dynamic_agents >/dev/null; then
  smoke_fail "prune_missing_dynamic_agents not defined after sourcing bridge-sync.sh"
fi

# --------------------------------------------------------------------------
# Stub surface — minimal in-memory state that `prune_missing_dynamic_agents`
# consults. These intentionally override the real lib/bridge-state.sh +
# lib/bridge-agents.sh helpers that the source above pulled in, so the
# smoke can exercise grace logic without driving a real tmux session,
# SQLite queue, or roster file. Defined AFTER `source bridge-sync.sh` so
# the real definitions cannot win the bind race.
# --------------------------------------------------------------------------

declare -g -A STUB_DYNAMIC_AGENTS=()   # agent -> 1 (presence test)
declare -g -A STUB_CREATED_AT=()       # agent -> epoch
declare -g -A STUB_ACTIVE=()           # agent -> 1 if tmux session present
declare -g -A STUB_ARCHIVED=()         # agent -> 1 when archive called
declare -g -A STUB_REMOVED=()          # agent -> 1 when remove-file called

# Shadows of the real helpers. Names match exactly what bridge-sync.sh
# calls so the stubbed environment behaves identically to the live one
# from the grace-check's point of view.
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
  return 0
}

bridge_warn() {
  printf '[warn] %s\n' "$*" >&2
}

# BRIDGE_AGENT_CREATED_AT is the associative array prune_missing_dynamic_agents
# reads from. bridge-agents.sh declared it with `-g -A`; re-declare-and-
# clear here (after sourcing bridge-sync.sh) so the smoke owns the
# contents but the associative type stays. A bare `=()` here would flip
# it to an indexed array and then `["$agent"]=...` would evaluate the
# index in arithmetic context, tripping `set -u` on a string key.
declare -g -A BRIDGE_AGENT_CREATED_AT=()

# Reset stub state between cases. The `unset && declare -A` pair is
# load-bearing — a bare `name=()` on an associative array re-types it
# to indexed and then string-keyed assignments fail under `set -u`.
reset_stubs() {
  unset STUB_DYNAMIC_AGENTS STUB_CREATED_AT STUB_ACTIVE STUB_ARCHIVED STUB_REMOVED
  unset BRIDGE_AGENT_CREATED_AT CLAIMED_SESSION_IDS PRUNED_DYNAMIC
  declare -g -A STUB_DYNAMIC_AGENTS=()
  declare -g -A STUB_CREATED_AT=()
  declare -g -A STUB_ACTIVE=()
  declare -g -A STUB_ARCHIVED=()
  declare -g -A STUB_REMOVED=()
  declare -g -A BRIDGE_AGENT_CREATED_AT=()
  declare -g -A CLAIMED_SESSION_IDS=()
  declare -g -A PRUNED_DYNAMIC=()
}

register_dynamic_agent() {
  local agent="$1"
  local created_at="$2"
  STUB_DYNAMIC_AGENTS["$agent"]=1
  STUB_CREATED_AT["$agent"]="$created_at"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$created_at"
}

# --------------------------------------------------------------------------
# T1 — resolve_dynamic_start_grace_seconds behavior.
# --------------------------------------------------------------------------
test_grace_resolver() {
  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  smoke_assert_eq "300" "$(resolve_dynamic_start_grace_seconds)" \
    "T1a default when unset"

  BRIDGE_DYNAMIC_START_GRACE_SECONDS="600"
  smoke_assert_eq "600" "$(resolve_dynamic_start_grace_seconds)" \
    "T1b integer override honored"

  BRIDGE_DYNAMIC_START_GRACE_SECONDS="0"
  smoke_assert_eq "0" "$(resolve_dynamic_start_grace_seconds)" \
    "T1c zero is a valid integer (operator opt-in to immediate prune)"

  BRIDGE_DYNAMIC_START_GRACE_SECONDS="not-a-number"
  smoke_assert_eq "300" "$(resolve_dynamic_start_grace_seconds)" \
    "T1d malformed falls back to default 300"

  BRIDGE_DYNAMIC_START_GRACE_SECONDS=""
  smoke_assert_eq "300" "$(resolve_dynamic_start_grace_seconds)" \
    "T1e empty string falls back to default 300"

  BRIDGE_DYNAMIC_START_GRACE_SECONDS="-30"
  smoke_assert_eq "300" "$(resolve_dynamic_start_grace_seconds)" \
    "T1f negative value rejected by integer regex, falls back to 300"

  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
}

# --------------------------------------------------------------------------
# T2 — 60s-old dynamic survives default 300s grace.
# --------------------------------------------------------------------------
test_default_grace_preserves_young() {
  reset_stubs
  local now
  now="$(date +%s)"
  register_dynamic_agent "alpha-young" "$((now - 60))"

  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  prune_missing_dynamic_agents

  if [[ -n "${STUB_ARCHIVED[alpha-young]+x}" ]]; then
    smoke_fail "T2 60s-old dynamic incorrectly archived under default 300s grace"
  fi
  if [[ -n "${STUB_REMOVED[alpha-young]+x}" ]]; then
    smoke_fail "T2 60s-old dynamic file incorrectly removed under default 300s grace"
  fi
  if [[ -n "${PRUNED_DYNAMIC[alpha-young]+x}" ]]; then
    smoke_fail "T2 alpha-young marked as PRUNED_DYNAMIC despite young age"
  fi
}

# --------------------------------------------------------------------------
# T3 — 6h-old dynamic is still pruned.
# --------------------------------------------------------------------------
test_stale_dynamic_still_pruned() {
  reset_stubs
  local now
  now="$(date +%s)"
  register_dynamic_agent "beta-stale" "$((now - 21600))"  # 6h ago

  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  prune_missing_dynamic_agents

  if [[ -z "${STUB_ARCHIVED[beta-stale]+x}" ]]; then
    smoke_fail "T3 6h-old dynamic was not archived (stale-prune regression)"
  fi
  if [[ -z "${STUB_REMOVED[beta-stale]+x}" ]]; then
    smoke_fail "T3 6h-old dynamic file was not removed (stale-prune regression)"
  fi
  if [[ -z "${PRUNED_DYNAMIC[beta-stale]+x}" ]]; then
    smoke_fail "T3 beta-stale missing from PRUNED_DYNAMIC after prune"
  fi
}

# --------------------------------------------------------------------------
# T4 — operator override shrinks the grace.
# --------------------------------------------------------------------------
test_operator_override_shrinks_grace() {
  reset_stubs
  local now
  now="$(date +%s)"
  register_dynamic_agent "gamma-override" "$((now - 180))"  # 3 min ago

  BRIDGE_DYNAMIC_START_GRACE_SECONDS=120
  prune_missing_dynamic_agents
  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS

  if [[ -z "${STUB_ARCHIVED[gamma-override]+x}" ]]; then
    smoke_fail "T4 operator override (120s) failed to archive 180s-old dynamic"
  fi
  if [[ -z "${STUB_REMOVED[gamma-override]+x}" ]]; then
    smoke_fail "T4 operator override (120s) failed to remove 180s-old dynamic file"
  fi
}

# --------------------------------------------------------------------------
# T5 — active agents (tmux session present) are never pruned regardless
# of age. Guards the `bridge_agent_is_active "$agent"` short-circuit at
# the top of the prune loop from regressing.
# --------------------------------------------------------------------------
test_active_agent_not_pruned() {
  reset_stubs
  local now
  now="$(date +%s)"
  register_dynamic_agent "epsilon-active" "$((now - 21600))"  # 6h old
  STUB_ACTIVE[epsilon-active]=1  # has tmux session

  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  prune_missing_dynamic_agents

  if [[ -n "${STUB_ARCHIVED[epsilon-active]+x}" ]]; then
    smoke_fail "T5 active 6h-old dynamic was archived despite live tmux session"
  fi
}

smoke_run "T1 grace resolver behavior"                    test_grace_resolver
smoke_run "T2 default grace preserves 60s-old dynamic"    test_default_grace_preserves_young
smoke_run "T3 6h-old dynamic still pruned"                test_stale_dynamic_still_pruned
smoke_run "T4 operator override shrinks grace"            test_operator_override_shrinks_grace
smoke_run "T5 active agent not pruned regardless of age"  test_active_agent_not_pruned

smoke_log "all checks passed"
