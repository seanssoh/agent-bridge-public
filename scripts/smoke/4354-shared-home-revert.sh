#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/4354-shared-home-revert.sh — shared-mode HOME=revert.
#
# Pins the #4354 invariant:
#   * shared agents launch with operator HOME for generic ~/.config tools
#   * Claude state remains under per-agent CLAUDE_CONFIG_DIR
#   * channel launch command regeneration must not inject per-agent HOME
#   * shared credential config consolidation is sentinel-gated,
#     non-destructive, and idempotent

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:4354-shared-home-revert][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="4354-shared-home-revert"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd rsync

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
export HOME="$OPERATOR_HOME"
export BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME"
mkdir -p "$OPERATOR_HOME/.config"

# shellcheck source=bridge-lib.sh
source "$REPO_ROOT/bridge-lib.sh"
# shellcheck source=lib/bridge-isolation-v2-migrate.sh
source "$REPO_ROOT/lib/bridge-isolation-v2-migrate.sh"

declare -ga BRIDGE_AGENT_IDS
declare -gA BRIDGE_AGENT_DESC
declare -gA BRIDGE_AGENT_ENGINE
declare -gA BRIDGE_AGENT_SESSION
declare -gA BRIDGE_AGENT_WORKDIR
declare -gA BRIDGE_AGENT_SOURCE
declare -gA BRIDGE_AGENT_CREATED_AT
declare -gA BRIDGE_AGENT_SESSION_ID
declare -gA BRIDGE_AGENT_ISOLATION_MODE
declare -gA BRIDGE_AGENT_OS_USER
declare -gA BRIDGE_AGENT_CHANNELS

register_shared_agent() {
  local agent="$1"
  local agent_home="$BRIDGE_AGENT_ROOT_V2/$agent/home"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"

  mkdir -p "$agent_home/.claude/projects" "$workdir"
  BRIDGE_AGENT_IDS+=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent shared HOME-revert fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
  BRIDGE_AGENT_ISOLATION_MODE["$agent"]="shared"
}

AGENT="home-revert-shared"
register_shared_agent "$AGENT"
AGENT_HOME="$BRIDGE_AGENT_ROOT_V2/$AGENT/home"
AGENT_CONFIG="$AGENT_HOME/.claude"

test_shared_resolvers_split_home_and_config() {
  local resolved_home resolved_config
  resolved_home="$(bridge_agent_claude_home_dir "$AGENT")"
  resolved_config="$(bridge_agent_claude_config_dir "$AGENT")"
  smoke_assert_eq "$OPERATOR_HOME" "$resolved_home" \
    "shared bridge_agent_claude_home_dir resolves operator HOME"
  smoke_assert_eq "$AGENT_CONFIG" "$resolved_config" \
    "shared bridge_agent_claude_config_dir resolves per-agent .claude"
}

test_channel_launch_env_uses_operator_home() {
  local raw launch teams_dir
  BRIDGE_AGENT_CHANNELS["$AGENT"]="plugin:teams@agent-bridge"
  mkdir -p "$AGENT_HOME/.teams"
  teams_dir="$(bridge_agent_teams_state_dir "$AGENT")"
  raw="claude --dangerously-load-development-channels plugin:teams@agent-bridge --name $AGENT"
  launch="$(bridge_claude_launch_with_channel_state_dirs "$AGENT" "$raw")"
  smoke_assert_contains "$launch" "HOME=$OPERATOR_HOME" \
    "channel launch injects operator HOME for shared agent"
  smoke_assert_not_contains "$launch" "HOME=$AGENT_HOME" \
    "channel launch does not inject per-agent HOME for shared agent"
  smoke_assert_contains "$launch" "CLAUDE_CONFIG_DIR=$AGENT_CONFIG" \
    "channel launch injects per-agent CLAUDE_CONFIG_DIR"
  smoke_assert_contains "$launch" "TEAMS_STATE_DIR=$teams_dir" \
    "channel launch still canonicalizes plugin state dir"
}

test_auto_memory_leaf_remains_agent_scoped() {
  local body
  body="$(awk '/^bridge_ensure_auto_memory_isolation\(\) \{/,/^}/' "$REPO_ROOT/bridge-agent.sh")"
  smoke_assert_contains "$body" 'expected = f"~/.claude/auto-memory/{slug}/{agent}"' \
    "auto-memory expected path includes the agent leaf"
}

test_credential_consolidation_and_idempotency() {
  local source_gh target_gh sentinel backup_count backup_path
  local operator_hosts_before operator_hosts_after consolidation_output
  source_gh="$AGENT_HOME/.config/gh"
  target_gh="$OPERATOR_HOME/.config/gh"
  mkdir -p "$source_gh" "$target_gh"
  printf 'source: agent-stub\n' >"$source_gh/hosts.yml"
  printf 'source: agent-only\n' >"$source_gh/agent-only.yml"
  printf 'source: operator-valid-token\n' >"$target_gh/hosts.yml"
  printf 'source: operator\n' >"$target_gh/operator.yml"
  operator_hosts_before="$SMOKE_TMP_ROOT/operator-hosts-before.yml"
  operator_hosts_after="$SMOKE_TMP_ROOT/operator-hosts-after.yml"
  cp "$target_gh/hosts.yml" "$operator_hosts_before"

  consolidation_output="$(bridge_isolation_v2_migrate_shared_credential_configs \
    "$BRIDGE_DATA_ROOT" "$BRIDGE_HOME" 2>&1)"
  cp "$target_gh/hosts.yml" "$operator_hosts_after"

  [[ -L "$source_gh" ]] || smoke_fail "credential consolidation should replace source gh dir with a symlink"
  smoke_assert_eq "$target_gh" "$(readlink "$source_gh")" \
    "credential consolidation symlink points at operator gh config"
  cmp -s "$operator_hosts_before" "$operator_hosts_after" \
    || smoke_fail "credential consolidation must not overwrite operator hosts.yml with agent stub"
  smoke_assert_file_exists "$target_gh/hosts.yml" \
    "credential consolidation preserves operator gh hosts"
  smoke_assert_file_exists "$target_gh/agent-only.yml" \
    "credential consolidation mirrors agent-only gh files into operator config"
  smoke_assert_file_exists "$target_gh/operator.yml" \
    "credential consolidation preserves existing operator gh files"
  smoke_assert_contains "$consolidation_output" "kept operator $target_gh/hosts.yml" \
    "credential consolidation warns on divergent operator/agent overlap"
  sentinel="$AGENT_HOME/.creds-consolidated.sentinel"
  smoke_assert_file_exists "$sentinel" \
    "credential consolidation writes per-agent sentinel"
  smoke_assert_contains "$(cat "$sentinel")" "status=ok" \
    "credential sentinel records ok status"
  backup_count="$(find "$AGENT_HOME/.config" -maxdepth 1 -type d -name 'gh.pre-home-revert.*' | wc -l | tr -d ' ')"
  smoke_assert_eq "1" "$backup_count" \
    "credential consolidation preserves exactly one backup dir"
  backup_path="$(find "$AGENT_HOME/.config" -maxdepth 1 -type d -name 'gh.pre-home-revert.*' -print -quit)"
  smoke_assert_file_exists "$backup_path/hosts.yml" \
    "credential consolidation backup preserves source contents"
  smoke_assert_contains "$(cat "$backup_path/hosts.yml")" "agent-stub" \
    "credential consolidation backup preserves divergent agent stub"

  bridge_isolation_v2_migrate_shared_credential_configs \
    "$BRIDGE_DATA_ROOT" "$BRIDGE_HOME"
  backup_count="$(find "$AGENT_HOME/.config" -maxdepth 1 -type d -name 'gh.pre-home-revert.*' | wc -l | tr -d ' ')"
  smoke_assert_eq "1" "$backup_count" \
    "credential consolidation is idempotent after sentinel"
}

test_wrong_symlink_fails_closed() {
  local bad_agent bad_home bad_source wrong_target
  bad_agent="home-revert-badlink"
  register_shared_agent "$bad_agent"
  bad_home="$BRIDGE_AGENT_ROOT_V2/$bad_agent/home"
  wrong_target="$SMOKE_TMP_ROOT/wrong-gh"
  mkdir -p "$bad_home/.config" "$wrong_target"
  bad_source="$bad_home/.config/gh"
  ln -s "$wrong_target" "$bad_source"

  if bridge_isolation_v2_migrate_consolidate_agent_creds \
      "$bad_agent" "$bad_home" "$OPERATOR_HOME"; then
    smoke_fail "wrong gh symlink should fail closed"
  fi
  smoke_assert_eq "$wrong_target" "$(readlink "$bad_source")" \
    "wrong symlink is not clobbered"
}

test_existing_correct_symlink_is_absorbed() {
  local link_agent link_home target_gh source_gh sentinel
  link_agent="home-revert-existing-link"
  register_shared_agent "$link_agent"
  link_home="$BRIDGE_AGENT_ROOT_V2/$link_agent/home"
  target_gh="$OPERATOR_HOME/.config/gh"
  source_gh="$link_home/.config/gh"
  mkdir -p "$link_home/.config" "$target_gh"
  ln -s "$target_gh" "$source_gh"

  bridge_isolation_v2_migrate_consolidate_agent_creds \
    "$link_agent" "$link_home" "$OPERATOR_HOME"

  [[ -L "$source_gh" ]] || smoke_fail "existing correct gh symlink should remain a symlink"
  smoke_assert_eq "$target_gh" "$(readlink "$source_gh")" \
    "existing correct gh symlink still points at operator gh config"
  sentinel="$link_home/.creds-consolidated.sentinel"
  smoke_assert_file_exists "$sentinel" \
    "existing correct symlink writes consolidation sentinel"
  smoke_assert_contains "$(cat "$sentinel")" "gh:ok;" \
    "existing correct symlink records gh ok"
}

test_iso_agent_is_skipped_by_bulk_consolidation() {
  local iso_agent iso_home
  iso_agent="home-revert-iso"
  iso_home="$BRIDGE_AGENT_ROOT_V2/$iso_agent/home"
  mkdir -p "$iso_home/.config/gh"
  printf 'iso\n' >"$iso_home/.config/gh/hosts.yml"
  BRIDGE_AGENT_IDS+=("$iso_agent")
  BRIDGE_AGENT_DESC["$iso_agent"]="$iso_agent iso skip fixture"
  BRIDGE_AGENT_ENGINE["$iso_agent"]="claude"
  BRIDGE_AGENT_SESSION["$iso_agent"]="$iso_agent"
  BRIDGE_AGENT_WORKDIR["$iso_agent"]="$BRIDGE_AGENT_ROOT_V2/$iso_agent/workdir"
  BRIDGE_AGENT_SOURCE["$iso_agent"]="static"
  BRIDGE_AGENT_CREATED_AT["$iso_agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$iso_agent"]=""
  BRIDGE_AGENT_ISOLATION_MODE["$iso_agent"]="linux-user"
  BRIDGE_AGENT_OS_USER["$iso_agent"]="agent-bridge-home-revert-iso"

  local saved_platform="${BRIDGE_HOST_PLATFORM_OVERRIDE:-}"
  export BRIDGE_HOST_PLATFORM_OVERRIDE="Linux"
  bridge_isolation_v2_migrate_shared_credential_configs \
    "$BRIDGE_DATA_ROOT" "$BRIDGE_HOME"
  export BRIDGE_HOST_PLATFORM_OVERRIDE="$saved_platform"
  [[ ! -f "$iso_home/.creds-consolidated.sentinel" ]] \
    || smoke_fail "iso agent should not receive shared credential consolidation sentinel"
  [[ -d "$iso_home/.config/gh" && ! -L "$iso_home/.config/gh" ]] \
    || smoke_fail "iso agent gh config should remain a real directory"
}

smoke_run "shared resolvers split HOME and config" test_shared_resolvers_split_home_and_config
smoke_run "channel launch env uses operator HOME" test_channel_launch_env_uses_operator_home
smoke_run "auto-memory path keeps per-agent leaf" test_auto_memory_leaf_remains_agent_scoped
smoke_run "credential consolidation and idempotency" test_credential_consolidation_and_idempotency
smoke_run "wrong symlink fails closed" test_wrong_symlink_fails_closed
smoke_run "existing correct symlink is absorbed" test_existing_correct_symlink_is_absorbed
smoke_run "iso agent skipped by bulk consolidation" test_iso_agent_is_skipped_by_bulk_consolidation

smoke_log "PASS"
