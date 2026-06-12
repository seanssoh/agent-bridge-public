#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1852-dynamic-agent-restart.sh — Issue #1852.
#
# `agent restart <dynamic-agent>` used to be a DESTROY verb for dynamic
# agents: run_restart kills the session, bridge_refresh_runtime_state →
# bridge-sync.sh prune_missing_dynamic_agents archives + deletes the
# `state/agents/<a>.env` active-env file (the dynamic agent's ONLY
# registration), and the relaunch leg's standalone `bridge-start.sh`
# re-loads the roster, finds static roles only, and dies with
# "등록된 에이전트가 아닙니다" — leaving the agent fully deregistered +
# stopped. Per #1795, operator-created dynamics are first-class and must
# never be destroyed by a restart.
#
# The fix (bridge-agent.sh::run_restart + lib/bridge-agents.sh helpers):
#   1. Capture source=dynamic up front; fail closed BEFORE the kill if the
#      recorded metadata cannot reconstruct a launchable registration.
#   2. Re-materialize the active-env file from the in-memory roster maps
#      after every post-kill refresh (the same write-env-then-relaunch
#      mechanism the supported `--name --workdir --replace` recreate uses)
#      so the standalone relaunch re-loads the same dynamic agent.
#   3. Dynamic rollback path retries the relaunch instead of the static-
#      only managed-block restore, leaving the agent stopped-but-REGISTERED
#      on failure (never deregistered).
#
# Test plan (bash helpers only, no live tmux):
#   T1. bridge_agent_restart_dynamic_recreate_hint reconstructs the
#       supported recreate command from recorded engine/workdir/loop
#       (claude+loop=1 ⇒ "--loop"; codex+loop=0 ⇒ no "--loop").
#   T2. bridge_agent_restart_dynamic_unsupported_guidance is fail-closed
#       guidance: it names the recreate hint AND states the running session
#       was left intact (non-destructive).
#   T3. The active-env reassert contract: after the prune deletes the
#       dynamic .env, bridge_write_dynamic_agent_file rewrites it from the
#       in-memory maps and a fresh bridge_load_roster re-registers the SAME
#       dynamic agent (source=dynamic, engine/workdir/loop preserved). This
#       is what makes the standalone relaunch leg succeed instead of dying
#       "등록된 에이전트가 아닙니다".
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; never touches
# the operator's live runtime.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses no command
# substitution feeding a heredoc-stdin and no `<<<` here-strings into
# bridge functions.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (macOS ships /bin/bash 3.2).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1852-dynamic-agent-restart] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1852-dynamic-agent-restart"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1852-dynamic-agent-restart"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

for fn in \
  bridge_agent_restart_dynamic_recreate_hint \
  bridge_agent_restart_dynamic_unsupported_guidance \
  bridge_write_dynamic_agent_file \
  bridge_dynamic_agent_file_for \
  bridge_load_roster \
  bridge_reset_roster_maps \
  bridge_agent_source; do
  if ! declare -F "$fn" >/dev/null; then
    smoke_fail "$fn not defined after sourcing bridge-lib.sh"
  fi
done

# Stub the v2 sudo-handoff write path so the dynamic env write takes the
# plain direct-write branch (the smoke is not a Linux v2 isolated UID).
bridge_state_v2_isolated_target() {
  return 1
}

bridge_reset_roster_maps

# T1 — recreate hint reconstructs the supported command from metadata.
test_recreate_hint() {
  bridge_reset_roster_maps
  local agent="dyn-1852-a"
  local workdir="$SMOKE_TMP_ROOT/work-$agent"
  mkdir -p "$workdir"

  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="dynamic"

  local hint=""
  hint="$(bridge_agent_restart_dynamic_recreate_hint "$agent")"
  smoke_assert_contains "$hint" "--claude" "T1 hint names the claude engine"
  smoke_assert_contains "$hint" "--name $agent" "T1 hint names the agent"
  smoke_assert_contains "$hint" "--workdir $workdir" "T1 hint carries the recorded workdir"
  smoke_assert_contains "$hint" "--replace" "T1 hint uses the replace recreate flow"
  smoke_assert_contains "$hint" "--loop" "T1 loop=1 ⇒ hint includes --loop"

  # codex + loop=0 ⇒ no --loop, engine swapped.
  BRIDGE_AGENT_ENGINE["$agent"]="codex"
  BRIDGE_AGENT_LOOP["$agent"]="0"
  hint="$(bridge_agent_restart_dynamic_recreate_hint "$agent")"
  smoke_assert_contains "$hint" "--codex" "T1 hint names the codex engine"
  smoke_assert_not_contains "$hint" "--loop" "T1 loop=0 ⇒ hint omits --loop"
}

# T2 — fail-closed guidance is non-destructive and points at the recreate.
test_unsupported_guidance() {
  bridge_reset_roster_maps
  local agent="dyn-1852-b"
  local workdir="$SMOKE_TMP_ROOT/work-$agent"
  mkdir -p "$workdir"

  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="dynamic"

  local guidance=""
  guidance="$(bridge_agent_restart_dynamic_unsupported_guidance "$agent")"
  smoke_assert_contains "$guidance" "left intact" \
    "T2 guidance states the running session was left intact (non-destructive)"
  smoke_assert_contains "$guidance" "agent-bridge --claude --name $agent" \
    "T2 guidance embeds the supported recreate command"
}

# T3 — the active-env reassert contract. The prune deletes the dynamic
# .env; rewriting it from the in-memory maps re-registers the SAME dynamic
# agent on the next bridge_load_roster (so the standalone relaunch leg no
# longer dies "등록된 에이전트가 아닙니다").
test_active_env_reassert() {
  bridge_reset_roster_maps
  local agent="dyn-1852-c"
  local workdir="$SMOKE_TMP_ROOT/work-$agent"
  mkdir -p "$workdir"

  local active_file=""
  active_file="$(bridge_dynamic_agent_file_for "$agent")"
  mkdir -p "$(dirname "$active_file")"

  # Seed the in-memory maps the way bridge_load_roster would for a live
  # dynamic agent, then write the active-env file once (creation).
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="Ad hoc claude agent ($workdir)"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_EPHEMERAL["$agent"]="0"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="dynamic"
  BRIDGE_AGENT_META_FILE["$agent"]="$active_file"
  BRIDGE_AGENT_HISTORY_KEY["$agent"]="$(bridge_history_key_for claude "$agent" "$workdir")"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""

  bridge_write_dynamic_agent_file "$agent" "$active_file"
  smoke_assert_file_exists "$active_file" "T3 active-env file written at creation"

  # Simulate the destructive prune that fired after the kill: delete the
  # active-env file (this is exactly what left the agent deregistered).
  rm -f "$active_file"
  [[ -f "$active_file" ]] && smoke_fail "T3 precondition: active-env should be deleted by the simulated prune"

  # The fix: re-assert the active-env from the still-intact in-memory maps
  # (the kill never touched them). This is what run_restart now does after
  # bridge_refresh_runtime_state.
  bridge_write_dynamic_agent_file "$agent" "$active_file"
  smoke_assert_file_exists "$active_file" "T3 active-env re-materialized after prune"

  # A fresh roster load (the standalone relaunch leg's first step) must now
  # re-register the SAME dynamic agent from the rewritten file.
  bridge_reset_roster_maps
  bridge_load_roster

  smoke_assert_eq "dynamic" "$(bridge_agent_source "$agent")" \
    "T3 reloaded agent is registered as a dynamic source (not 'not a registered agent')"
  smoke_assert_eq "claude" "$(bridge_agent_engine "$agent")" \
    "T3 engine preserved across the reassert+reload"
  smoke_assert_eq "$workdir" "$(bridge_agent_workdir "$agent")" \
    "T3 workdir preserved across the reassert+reload"
  smoke_assert_eq "1" "$(bridge_agent_loop "$agent")" \
    "T3 loop flag preserved across the reassert+reload"
}

# Issue #1857: the #1854 restart path now routes every dynamic restart through
# the `--replace` recreate relaunch, which re-runs the per-agent plugin
# manifest sync (bridge-dev-plugin-cache.py, invoked by
# bridge_run_sync_dev_plugin_cache) with the bridge-owned ledger path exported
# as BRIDGE_PLUGIN_GRANT_LEDGER. That re-derivation MUST preserve operator-
# installed provisioning end-to-end — a restart that drops claude-hud etc. is
# the #1857 regression #1854 inherited. This tooth drives the REAL `sync` CLI
# entrypoint (not the helper in isolation) through the env contract the
# launcher exports, exercising the NO-channel recovery path a dynamic agent
# with only ad-hoc operator plugins hits on restart.
test_restart_preserves_provisioning() {
  smoke_require_cmd python3
  local proot="$SMOKE_TMP_ROOT/restart-plugins"
  local ledger="$SMOKE_TMP_ROOT/restart-ledger.json"
  mkdir -p "$proot/cache"
  # Pre-restart healthy state: operator plugin recorded in the ledger snapshot.
  # `channels` is EMPTY — a dynamic agent with no plugin: channels, only an
  # ad-hoc operator install (the exact scenario create-time materialization
  # missed: nothing to trigger a channel re-sync, yet the manifest got wiped).
  cat >"$ledger" <<'JSON'
{
  "channels": [],
  "installed_snapshot": {
    "version": 2,
    "plugins": {
      "claude-hud@jarrodwatts": [
        {"scope": "user", "installPath": "/operator/installed/claude-hud", "version": "9.9.9",
         "installedAt": "2026-01-01T00:00:00Z", "lastUpdated": "2026-01-01T00:00:00Z"}
      ]
    }
  }
}
JSON
  # The recreate re-scaffolded the per-agent plugins tree → live manifest came
  # back EMPTY (the verified live wipe signature).
  printf '{\n  "version": 2,\n  "plugins": {}\n}\n' >"$proot/installed_plugins.json"

  # Drive the REAL `sync` CLI as the launcher does, with the ledger env var the
  # restart path exports and an EMPTY channel set — proving the no-channel
  # recovery is reachable end-to-end through the production entrypoint.
  BRIDGE_CLAUDE_PLUGINS_ROOT="$proot" \
  BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="$proot/cache" \
  BRIDGE_PLUGIN_GRANT_LEDGER="$ledger" \
  python3 "$REPO_ROOT/bridge-dev-plugin-cache.py" sync \
    --channels "" --required-channels "" --optional-channels "" --agent restart-demo \
    >/dev/null 2>&1 \
    || smoke_fail "T4 restart sync CLI exited non-zero on a no-channel recovery pass"

  smoke_assert_file_exists "$proot/installed_plugins.json" \
    "T4 restart sync left a manifest"
  smoke_assert_contains "$(cat "$proot/installed_plugins.json")" "claude-hud@jarrodwatts" \
    "T4 #1854 restart path preserved the operator-installed plugin (claude-hud) end-to-end via BRIDGE_PLUGIN_GRANT_LEDGER"
}

smoke_run "T1 recreate hint reconstructs supported command"   test_recreate_hint
smoke_run "T2 unsupported guidance is non-destructive"         test_unsupported_guidance
smoke_run "T3 active-env reassert re-registers dynamic agent"  test_active_env_reassert
smoke_run "T4 #1854 restart path preserves provisioning (#1857)" test_restart_preserves_provisioning

smoke_log "all checks passed"
