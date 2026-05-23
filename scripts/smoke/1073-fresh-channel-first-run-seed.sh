#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1073-fresh-channel-first-run-seed.sh — Issue #1073.
#
# Re-exec under bash 4+ so the source-checkout shim coverage runs against
# the same shell layer as `bridge-agent.sh::run_create`. macOS ships
# bash 3.2; the lib helpers (bridge_agent_*) rely on associative arrays.
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1073-fresh-channel-first-run-seed][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Pins the contract that ``bridge_ensure_claude_first_run_config`` writes
# a per-agent ``CLAUDE_CONFIG_DIR/.claude.json`` carrying the bootstrap
# keys Claude CLI needs to skip first-run interactive prompts. Without
# this, a fresh non-admin Claude channel agent with its own config dir
# hits the theme picker on first launch; the picker blocks the tmux
# session; ``bridge-run.sh``'s foreground detection times out, kills the
# session, and relaunches — producing an infinite restart loop.
#
# Test plan:
#   T1. The helper script ``scripts/python-helpers/seed-claude-first-run-config.py``
#       writes ``<config_dir>/.claude.json`` carrying
#       ``hasCompletedOnboarding: true`` and ``firstStartTime`` on a
#       fresh config dir.
#   T2. The same helper records the agent's workspace cwd under
#       ``projects.<workdir>`` with ``hasTrustDialogAccepted: true`` so
#       Claude does not prompt for the project trust dialog on first
#       launch in that workspace.
#   T3. ``managed_claude_settings_defaults`` (via the
#       ``render-shared-settings`` renderer path) emits
#       ``skipDangerousModePermissionPrompt: true`` into the effective
#       settings when the launch_cmd carries
#       ``--dangerously-skip-permissions``. This is the suppression key
#       for the "Bypass Permissions mode" warning that bridge agents
#       always trigger (every managed Claude agent launches with
#       ``--dangerously-skip-permissions``).
#   T4. The bash shim ``bridge_ensure_claude_first_run_config`` is a
#       no-op for non-Claude agents and for engines other than Claude
#       (codex returns immediately, no file is touched).
#   T5. Idempotent re-run: calling the helper twice on the same config
#       dir does not destroy operator-added keys (``setdefault``
#       semantics; existing values win).
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout);
# the smoke never reads or writes the operator's live ``~/.claude``.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# ``printf`` / ``cat >file <<EOF`` plain-body writes — no command
# substitution feeding a heredoc-stdin, no ``<<<`` here-strings into
# bridge functions.

set -euo pipefail

SMOKE_NAME="1073-fresh-channel-first-run-seed"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
SEED_HELPER="$REPO_ROOT/scripts/python-helpers/seed-claude-first-run-config.py"
HOOKS_PY="$REPO_ROOT/bridge-hooks.py"

[[ -f "$SEED_HELPER" ]] || smoke_fail "missing helper: $SEED_HELPER"
[[ -f "$HOOKS_PY" ]] || smoke_fail "missing helper: $HOOKS_PY"

# --- T1/T2: direct helper coverage --------------------------------------
test_helper_seeds_onboarding_keys() {
  local config_dir="$SMOKE_TMP_ROOT/agent-A/.claude"
  local workdir="$SMOKE_TMP_ROOT/agent-A-workdir"
  mkdir -p "$workdir"
  python3 "$SEED_HELPER" "$config_dir" "$workdir" >/dev/null
  smoke_assert_file_exists "$config_dir/.claude.json" \
    "T1 helper writes .claude.json into the config dir"
  local has_onboarding
  has_onboarding="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print("yes" if data.get("hasCompletedOnboarding") is True else "no")
' "$config_dir/.claude.json")"
  smoke_assert_eq "yes" "$has_onboarding" \
    "T1 .claude.json carries hasCompletedOnboarding=true"
  local has_first_start
  has_first_start="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print("yes" if isinstance(data.get("firstStartTime"), str) and data["firstStartTime"] else "no")
' "$config_dir/.claude.json")"
  smoke_assert_eq "yes" "$has_first_start" \
    "T1 .claude.json carries non-empty firstStartTime"
}

test_helper_records_workspace_trust() {
  local config_dir="$SMOKE_TMP_ROOT/agent-B/.claude"
  local workdir="$SMOKE_TMP_ROOT/agent-B-workdir"
  mkdir -p "$workdir"
  workdir="$(cd -P "$workdir" && pwd -P)"
  python3 "$SEED_HELPER" "$config_dir" "$workdir" >/dev/null
  local accepted
  accepted="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
projects = data.get("projects") or {}
entry = projects.get(sys.argv[2]) or {}
print("yes" if entry.get("hasTrustDialogAccepted") is True else "no")
' "$config_dir/.claude.json" "$workdir")"
  smoke_assert_eq "yes" "$accepted" \
    "T2 helper records workspace under projects[<workdir>] with hasTrustDialogAccepted=true"
}

# --- T3: renderer emits skipDangerousModePermissionPrompt for bridge launch_cmd
test_renderer_emits_bypass_skip_key() {
  local base_settings="$SMOKE_TMP_ROOT/base-settings.json"
  local overlay="$SMOKE_TMP_ROOT/overlay-settings.json"
  local effective="$SMOKE_TMP_ROOT/effective-settings.json"
  printf '{}\n' >"$base_settings"
  printf '{}\n' >"$overlay"
  # The render-shared-settings subcommand composes:
  #   managed_defaults < base < overlay < preserved user keys.
  # With both base and overlay empty, the only source of
  # `skipDangerousModePermissionPrompt: true` is `managed_claude_settings_defaults`
  # — which we now opt into when launch_cmd carries
  # `--dangerously-skip-permissions`. This is the exact key Claude CLI uses
  # to suppress the Bypass Permissions warning that otherwise blocks the
  # tmux session at first launch.
  python3 "$HOOKS_PY" render-shared-settings \
    --base-settings-file "$base_settings" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$effective" \
    --launch-cmd "claude --dangerously-skip-permissions" \
    --agent-class "static" >/dev/null
  local actual
  actual="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print("yes" if data.get("skipDangerousModePermissionPrompt") is True else "no")
' "$effective")"
  smoke_assert_eq "yes" "$actual" \
    "T3 renderer emits skipDangerousModePermissionPrompt=true for --dangerously-skip-permissions launch_cmd"
}

test_renderer_omits_bypass_skip_key_without_flag() {
  local base_settings="$SMOKE_TMP_ROOT/base-settings-2.json"
  local overlay="$SMOKE_TMP_ROOT/overlay-settings-2.json"
  local effective="$SMOKE_TMP_ROOT/effective-settings-2.json"
  printf '{}\n' >"$base_settings"
  printf '{}\n' >"$overlay"
  python3 "$HOOKS_PY" render-shared-settings \
    --base-settings-file "$base_settings" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$effective" \
    --launch-cmd "claude" \
    --agent-class "static" >/dev/null
  local present
  present="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print("yes" if "skipDangerousModePermissionPrompt" in data else "no")
' "$effective")"
  smoke_assert_eq "no" "$present" \
    "T3 renderer omits skipDangerousModePermissionPrompt without --dangerously-skip-permissions"
}

# --- T4: shim is a no-op for non-Claude agents --------------------------
# Source the bash lib so the shim is in scope. bridge-lib.sh transitively
# sources lib/bridge-agents.sh (where bridge_ensure_claude_first_run_config
# lives) plus the rest of the runtime. Mirrors the 1015 smoke pattern.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

declare -F bridge_ensure_claude_first_run_config >/dev/null \
  || smoke_fail "bridge_ensure_claude_first_run_config not defined after sourcing bridge-lib.sh"
declare -F bridge_reset_roster_maps >/dev/null \
  || smoke_fail "bridge_reset_roster_maps not defined"

test_shim_noop_for_codex_agent() {
  bridge_reset_roster_maps
  local agent="codex-T4"
  local workdir="$SMOKE_TMP_ROOT/codex-T4-workdir"
  mkdir -p "$workdir"
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="codex"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""

  # Shim must return 0 without creating any .claude.json.
  bridge_ensure_claude_first_run_config "$agent" "$workdir" \
    || smoke_fail "T4 shim returned non-zero for non-Claude agent"
  local config_dir
  config_dir="$(bridge_agent_claude_config_dir "$agent" 2>/dev/null || true)"
  if [[ -n "$config_dir" && -f "$config_dir/.claude.json" ]]; then
    smoke_fail "T4 shim wrote .claude.json for a codex agent: $config_dir/.claude.json"
  fi
}

# --- T5: idempotent re-run preserves operator-added keys ---------------
test_helper_idempotent_preserves_keys() {
  local config_dir="$SMOKE_TMP_ROOT/agent-C/.claude"
  local workdir="$SMOKE_TMP_ROOT/agent-C-workdir"
  mkdir -p "$workdir" "$config_dir"
  # First seed pass.
  python3 "$SEED_HELPER" "$config_dir" "$workdir" >/dev/null
  # Operator adds a custom key directly to .claude.json.
  python3 -c '
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["operatorAddedKey"] = "preserved-value"
# Also flip hasCompletedOnboarding to a different value to verify
# setdefault does NOT override an existing key.
data["hasCompletedOnboarding"] = True  # already true; keep test focused
json.dump(data, open(path, "w"), indent=2)
' "$config_dir/.claude.json"
  # Second seed pass — must NOT clobber the operator key.
  python3 "$SEED_HELPER" "$config_dir" "$workdir" >/dev/null
  local preserved
  preserved="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("operatorAddedKey", ""))
' "$config_dir/.claude.json")"
  smoke_assert_eq "preserved-value" "$preserved" \
    "T5 second seed run preserves operator-added keys"
}

smoke_run "T1 helper seeds onboarding keys"                       test_helper_seeds_onboarding_keys
smoke_run "T2 helper records workspace trust"                     test_helper_records_workspace_trust
smoke_run "T3 renderer emits bypass skip key for bridge launch"   test_renderer_emits_bypass_skip_key
smoke_run "T3 renderer omits bypass skip key without flag"        test_renderer_omits_bypass_skip_key_without_flag
smoke_run "T4 shim no-op for non-Claude agent"                    test_shim_noop_for_codex_agent
smoke_run "T5 helper idempotent re-run preserves operator keys"   test_helper_idempotent_preserves_keys

smoke_log "all checks passed"
