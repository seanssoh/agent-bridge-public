#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="hooks"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

codex_hooks_contract() {
  local hooks_file ensure_out status_out payload

  hooks_file="$SMOKE_TMP_ROOT/codex-home/.codex/hooks.json"
  ensure_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-codex-hooks \
      --bridge-home "$BRIDGE_HOME" \
      --python-bin "$(command -v python3)" \
      --codex-hooks-file "$hooks_file"
  )"
  smoke_assert_contains "$ensure_out" "hooks_file:" "codex hook ensure output"
  smoke_assert_file_exists "$hooks_file" "codex hooks file"

  payload="$(cat "$hooks_file")"
  smoke_assert_contains "$payload" "\"SessionStart\"" "codex hooks include SessionStart"
  smoke_assert_contains "$payload" "session-start.py --format codex" "codex hooks launch session-start helper"

  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-codex-hooks --codex-hooks-file "$hooks_file")"
  smoke_assert_contains "$status_out" "ok" "codex hook status"
}

claude_hooks_contract() {
  local workdir status_out payload

  workdir="$SMOKE_TMP_ROOT/claude-workdir"
  mkdir -p "$workdir"

  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-session-start-hook \
    --workdir "$workdir" \
    --bridge-home "$BRIDGE_HOME" \
    --python-bin "$(command -v python3)" >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-stop-hook \
    --workdir "$workdir" \
    --bridge-home "$BRIDGE_HOME" \
    --bash-bin bash >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-prompt-hook \
    --workdir "$workdir" \
    --bridge-home "$BRIDGE_HOME" \
    --bash-bin bash \
    --python-bin "$(command -v python3)" >/dev/null

  payload="$(cat "$workdir/.claude/settings.json")"
  smoke_assert_contains "$payload" "\"SessionStart\"" "Claude settings include SessionStart hook"
  smoke_assert_contains "$payload" "session-start.py" "Claude SessionStart hook command"
  smoke_assert_contains "$payload" "mark-idle.sh" "Claude Stop hook command"
  smoke_assert_contains "$payload" "clear-idle.sh" "Claude prompt hook command"

  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-session-start-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)")"
  smoke_assert_contains "$status_out" "ok" "Claude SessionStart hook status"
  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
  smoke_assert_contains "$status_out" "ok" "Claude Stop hook status"
  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
  smoke_assert_contains "$status_out" "ok" "Claude prompt hook status"
}

assert_claude_auto_compact_window() {
  local settings_file="$1"
  local expected="$2"
  local context="$3"

  python3 - "$settings_file" "$expected" "$context" <<'PY'
import json
import sys
from pathlib import Path

settings_file, expected, context = sys.argv[1:]
payload = json.loads(Path(settings_file).read_text(encoding="utf-8"))
actual = payload.get("autoCompactWindow")
if actual != int(expected):
    raise SystemExit(f"{context}: autoCompactWindow expected {expected}, got {actual!r}")
PY
}

assert_json_env_key() {
  local settings_file="$1"
  local key="$2"
  local expected="$3"
  local context="$4"

  python3 - "$settings_file" "$key" "$expected" "$context" <<'PY'
import json
import sys
from pathlib import Path

settings_file, key, expected, context = sys.argv[1:]
payload = json.loads(Path(settings_file).read_text(encoding="utf-8"))
actual = payload.get("env", {}).get(key)
if actual != expected:
    raise SystemExit(f"{context}: env.{key} expected {expected!r}, got {actual!r}")
PY
}

claude_shared_settings_context_defaults() {
  local case_dir base overlay effective isolated_root isolated_workdir link_output target

  case_dir="$SMOKE_TMP_ROOT/shared-settings"
  mkdir -p "$case_dir"
  base="$case_dir/settings.json"
  overlay="$case_dir/settings.local.json"
  effective="$case_dir/settings.effective.json"

  rm -f "$base" "$overlay" "$effective"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$base" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$effective" >/dev/null
  assert_claude_auto_compact_window "$effective" "400000" "bridge defaults"

  printf '%s\n' '{"autoCompactWindow":650000,"env":{"BASE_ONLY":"yes"}}' >"$base"
  rm -f "$overlay" "$effective"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$base" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$effective" >/dev/null
  assert_claude_auto_compact_window "$effective" "650000" "base overrides bridge defaults"
  assert_json_env_key "$effective" "BASE_ONLY" "yes" "base env key preserved"

  printf '%s\n' '{"autoCompactWindow":475000,"env":{"OVERLAY_ONLY":"yes"}}' >"$overlay"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$base" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$effective" >/dev/null
  assert_claude_auto_compact_window "$effective" "475000" "overlay overrides base and bridge defaults"
  assert_json_env_key "$effective" "BASE_ONLY" "yes" "base env key survives overlay merge"
  assert_json_env_key "$effective" "OVERLAY_ONLY" "yes" "overlay env key preserved"

  isolated_root="$SMOKE_TMP_ROOT/isolated-agent-root"
  isolated_workdir="$isolated_root/iso-agent"
  mkdir -p "$isolated_root/.claude" "$isolated_workdir"
  printf '%s\n' '{"autoCompactWindow":425000}' >"$isolated_root/.claude/settings.local.json"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$isolated_root/.claude/settings.json" \
    --overlay-settings-file "$isolated_root/.claude/settings.local.json" \
    --effective-settings-file "$isolated_root/.claude/settings.effective.json" >/dev/null
  link_output="$(
    python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" link-shared-settings \
      --workdir "$isolated_workdir" \
      --shared-settings-file "$isolated_root/.claude/settings.effective.json"
  )"
  smoke_assert_contains "$link_output" "settings_file: $isolated_workdir/.claude/settings.json" "isolated settings link output"
  [[ -L "$isolated_workdir/.claude/settings.json" ]] || smoke_fail "isolated settings should be a symlink"
  target="$(readlink "$isolated_workdir/.claude/settings.json")"
  smoke_assert_contains "$target" "../../.claude/settings.effective.json" "isolated settings symlink target"
  assert_claude_auto_compact_window "$isolated_root/.claude/settings.effective.json" "425000" "isolated overlay preserves operator override"
}

managed_custom_workdir_shared_settings() {
  local custom_workdir output target bash4_bin

  custom_workdir="$SMOKE_TMP_ROOT/custom-managed-workdir"
  mkdir -p "$custom_workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "custom-agent"
BRIDGE_AGENT_ENGINE["custom-agent"]="claude"
BRIDGE_AGENT_SESSION["custom-agent"]="custom-agent"
BRIDGE_AGENT_WORKDIR["custom-agent"]="$custom_workdir"
EOF

  bash4_bin="$BASH"
  if (( BASH_VERSINFO[0] < 4 )); then
    if [[ -x /opt/homebrew/bin/bash ]]; then
      bash4_bin="/opt/homebrew/bin/bash"
    elif [[ -x /usr/local/bin/bash ]]; then
      bash4_bin="/usr/local/bin/bash"
    fi
  fi

  output="$(
    "$bash4_bin" -c 'repo="$1"; workdir="$2"; source "$repo/bridge-lib.sh"; bridge_load_roster; bridge_ensure_claude_stop_hook "$workdir"' \
      _ "$SMOKE_REPO_ROOT" "$custom_workdir"
  )"
  smoke_assert_contains "$output" "settings_file: $custom_workdir/.claude/settings.json" "custom managed settings link output"
  [[ -L "$custom_workdir/.claude/settings.json" ]] || smoke_fail "custom managed workdir should use shared settings symlink"
  target="$(readlink "$custom_workdir/.claude/settings.json")"
  smoke_assert_contains "$target" "../bridge-home/agents/.claude/settings.effective.json" "custom managed settings symlink target"
  assert_claude_auto_compact_window "$BRIDGE_AGENT_HOME_ROOT/.claude/settings.effective.json" "400000" "custom managed shared settings"
}

hook_runtime_helpers() {
  local hook_workdir prompt_output session_output

  prompt_output="$(BRIDGE_AGENT_ID=hook-agent BRIDGE_HOME="$BRIDGE_HOME" python3 "$SMOKE_REPO_ROOT/hooks/prompt_timestamp.py")"
  smoke_assert_contains "$prompt_output" "hook-agent" "prompt timestamp helper includes agent id"

  hook_workdir="$BRIDGE_AGENT_HOME_ROOT/hook-agent"
  mkdir -p "$hook_workdir"
  session_output="$(
    BRIDGE_AGENT_ID=hook-agent \
      BRIDGE_AGENT_WORKDIR="$hook_workdir" \
      BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
      BRIDGE_HOME="$BRIDGE_HOME" \
      python3 "$SMOKE_REPO_ROOT/hooks/session_start.py"
  )"
  smoke_assert_contains "$session_output" "Agent Bridge queue protocol applies to hook-agent" "session_start helper emits queue protocol context"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "hooks"
  smoke_run "Codex hooks ensure/status" codex_hooks_contract
  smoke_run "Claude hooks ensure/status" claude_hooks_contract
  smoke_run "Claude shared settings context defaults" claude_shared_settings_context_defaults
  smoke_run "managed custom workdir shared settings" managed_custom_workdir_shared_settings
  smoke_run "hook runtime helper output" hook_runtime_helpers
  smoke_log "passed"
}

main "$@"
