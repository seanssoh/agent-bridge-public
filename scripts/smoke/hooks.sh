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
  local operator_home home_bridge home_workdir workdir status_out payload

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
  smoke_assert_contains "$payload" "$BRIDGE_HOME/hooks/prompt_timestamp.py" \
    "Claude prompt timestamp hook uses controller bridge home"
  smoke_assert_not_contains "$payload" "~/.agent-bridge/hooks/prompt_timestamp.py" \
    "Claude prompt timestamp hook must not resolve through agent HOME"

  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-session-start-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)")"
  smoke_assert_contains "$status_out" "ok" "Claude SessionStart hook status"
  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
  smoke_assert_contains "$status_out" "ok" "Claude Stop hook status"
  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
  smoke_assert_contains "$status_out" "ok" "Claude prompt hook status"

  operator_home="$SMOKE_TMP_ROOT/operator-home"
  home_bridge="$operator_home/.agent-bridge"
  home_workdir="$SMOKE_TMP_ROOT/home-relative-bridge-workdir"
  mkdir -p "$home_bridge" "$home_workdir"
  HOME="$operator_home" python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-prompt-hook \
    --workdir "$home_workdir" \
    --bridge-home "$home_bridge" \
    --bash-bin bash \
    --python-bin "$(command -v python3)" >/dev/null
  payload="$(cat "$home_workdir/.claude/settings.json")"
  smoke_assert_contains "$payload" "$home_bridge/hooks/prompt_timestamp.py" \
    "Claude prompt timestamp hook remains absolute when bridge home is under HOME"
  smoke_assert_not_contains "$payload" "~/.agent-bridge/hooks/prompt_timestamp.py" \
    "Claude prompt timestamp hook does not resolve through runtime HOME"
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
  # Issue #570: managed autoCompactWindow default is unconditionally 1_000_000.
  assert_claude_auto_compact_window "$effective" "1000000" "bridge defaults"

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

managed_v2_workdir_shared_settings() {
  local custom_workdir actual_workdir output target bash4_bin

  custom_workdir="$SMOKE_TMP_ROOT/custom-managed-workdir"
  actual_workdir="$BRIDGE_AGENT_ROOT_V2/custom-agent/workdir"
  mkdir -p "$custom_workdir" "$actual_workdir"
  # Issue #895: post-fix `bridge_agent_workdir` only returns the v2 anchor
  # (BRIDGE_AGENT_ROOT_V2/<agent>/workdir) when the agent's isolation
  # mode is `linux-user` (the privacy-invariant contract the anchor
  # exists for). For any other mode, including the default-shared
  # fallback, it now correctly honors the explicit BRIDGE_AGENT_WORKDIR.
  # This test exercises the v2-managed-linux-user path where the anchor
  # MUST win over the explicit workdir, so set isolation_mode=linux-user
  # explicitly. Without this opt-in, the resolver would (correctly)
  # honor `$custom_workdir`, and the test's "settings symlink lives at
  # the anchor" + "custom workdir receives no symlink" assertions would
  # fail — that would be exercising the shared-mode contract, not the
  # managed-v2 contract this test is named for.
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "custom-agent"
BRIDGE_AGENT_ENGINE["custom-agent"]="claude"
BRIDGE_AGENT_SOURCE["custom-agent"]="static"
BRIDGE_AGENT_SESSION["custom-agent"]="custom-agent"
BRIDGE_AGENT_WORKDIR["custom-agent"]="$custom_workdir"
BRIDGE_AGENT_ISOLATION_MODE["custom-agent"]="linux-user"
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
      _ "$SMOKE_REPO_ROOT" "$actual_workdir"
  )"
  smoke_assert_contains "$output" "settings_file: $actual_workdir/.claude/settings.json" "v2 managed settings link output"
  [[ -L "$actual_workdir/.claude/settings.json" ]] || smoke_fail "v2 managed workdir should use shared settings symlink"
  [[ ! -e "$custom_workdir/.claude/settings.json" ]] || smoke_fail "v2 should not write hooks into ignored explicit custom workdir"
  target="$(readlink "$actual_workdir/.claude/settings.json")"
  smoke_assert_contains "$target" "bridge-home/agents/.claude/settings.effective.json" "v2 managed settings symlink target"
  # Issue #570: managed autoCompactWindow default is unconditionally 1_000_000.
  assert_claude_auto_compact_window "$BRIDGE_AGENT_HOME_ROOT/.claude/settings.effective.json" "1000000" "v2 managed shared settings"
}

claude_settings_mode_source_gate() {
  # Issue #516: bridge_claude_settings_mode must gate the registered-workdir
  # branch on source=static. Dynamic claude agents register a workdir in
  # BRIDGE_AGENT_IDS too (bulk-register, dynamic spawn), and without the
  # source check the second branch would treat any registered workdir as
  # "shared" — handing dynamic agents the static-only managed
  # autoCompactWindow default (1_000_000 as of issue #570) instead of
  # leaving them on Claude Code's own native auto-compact handling.
  local case_root static_configured_workdir dynamic_configured_workdir within_root_workdir bash4_bin
  local static_workdir dynamic_workdir dynamic_under_root_configured_workdir
  local mode_dynamic mode_static mode_within_root mode_dynamic_under_root_configured

  case_root="$SMOKE_TMP_ROOT/settings-mode-gate"
  mkdir -p "$case_root"
  static_configured_workdir="$case_root/static-agent-workdir"
  dynamic_configured_workdir="$case_root/dynamic-agent-workdir"
  static_workdir="$BRIDGE_AGENT_ROOT_V2/static-agent/workdir"
  dynamic_workdir="$BRIDGE_AGENT_ROOT_V2/dynamic-agent/workdir"
  within_root_workdir="$BRIDGE_AGENT_HOME_ROOT/within-root-agent"
  dynamic_under_root_configured_workdir="$BRIDGE_AGENT_HOME_ROOT/dynamic-agent"
  mkdir -p "$static_configured_workdir" "$dynamic_configured_workdir" \
    "$static_workdir" "$dynamic_workdir" "$within_root_workdir" \
    "$dynamic_under_root_configured_workdir"

  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "static-agent"
BRIDGE_AGENT_ENGINE["static-agent"]="claude"
BRIDGE_AGENT_SOURCE["static-agent"]="static"
BRIDGE_AGENT_SESSION["static-agent"]="static-agent"
BRIDGE_AGENT_WORKDIR["static-agent"]="$static_configured_workdir"
BRIDGE_AGENT_ISOLATION_MODE["static-agent"]="linux-user"

bridge_add_agent_id_if_missing "dynamic-agent"
BRIDGE_AGENT_ENGINE["dynamic-agent"]="claude"
BRIDGE_AGENT_SOURCE["dynamic-agent"]="dynamic"
BRIDGE_AGENT_SESSION["dynamic-agent"]="dynamic-agent"
BRIDGE_AGENT_WORKDIR["dynamic-agent"]="$dynamic_under_root_configured_workdir"
BRIDGE_AGENT_ISOLATION_MODE["dynamic-agent"]="linux-user"
EOF

  bash4_bin="$BASH"
  if (( BASH_VERSINFO[0] < 4 )); then
    if [[ -x /opt/homebrew/bin/bash ]]; then
      bash4_bin="/opt/homebrew/bin/bash"
    elif [[ -x /usr/local/bin/bash ]]; then
      bash4_bin="/usr/local/bin/bash"
    fi
  fi

  # E1 — dynamic claude agent's v2 canonical workdir (outside HOME_ROOT) must
  # NOT classify as `shared`. Re-register the dynamic agent with the
  # outside-HOME_ROOT configured workdir for this case; v2 still resolves the
  # actual workdir to BRIDGE_AGENT_ROOT_V2/<agent>/workdir.
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "static-agent"
BRIDGE_AGENT_ENGINE["static-agent"]="claude"
BRIDGE_AGENT_SOURCE["static-agent"]="static"
BRIDGE_AGENT_SESSION["static-agent"]="static-agent"
BRIDGE_AGENT_WORKDIR["static-agent"]="$static_configured_workdir"
BRIDGE_AGENT_ISOLATION_MODE["static-agent"]="linux-user"

bridge_add_agent_id_if_missing "dynamic-agent"
BRIDGE_AGENT_ENGINE["dynamic-agent"]="claude"
BRIDGE_AGENT_SOURCE["dynamic-agent"]="dynamic"
BRIDGE_AGENT_SESSION["dynamic-agent"]="dynamic-agent"
BRIDGE_AGENT_WORKDIR["dynamic-agent"]="$dynamic_configured_workdir"
BRIDGE_AGENT_ISOLATION_MODE["dynamic-agent"]="linux-user"
EOF
  mode_dynamic="$(
    "$bash4_bin" -c 'repo="$1"; workdir="$2"; source "$repo/bridge-lib.sh"; bridge_load_roster; bridge_claude_settings_mode "$workdir"' \
      _ "$SMOKE_REPO_ROOT" "$dynamic_workdir"
  )"
  smoke_assert_eq "local" "$mode_dynamic" "E1: dynamic claude agent v2 workdir resolves as local (not shared)"

  # E2 — static claude agent's v2 canonical workdir classifies as `shared`.
  mode_static="$(
    "$bash4_bin" -c 'repo="$1"; workdir="$2"; source "$repo/bridge-lib.sh"; bridge_load_roster; bridge_claude_settings_mode "$workdir"' \
      _ "$SMOKE_REPO_ROOT" "$static_workdir"
  )"
  smoke_assert_eq "shared" "$mode_static" "E2: static claude agent v2 workdir resolves as shared"

  # E3 — workdir within BRIDGE_AGENT_HOME_ROOT and NOT registered as a
  # dynamic agent still resolves as `shared`. The dynamic short-circuit
  # only fires on exact-match registered workdirs, so unregistered paths
  # under the home root keep their static-by-construction default.
  mode_within_root="$(
    "$bash4_bin" -c 'repo="$1"; workdir="$2"; source "$repo/bridge-lib.sh"; bridge_load_roster; bridge_claude_settings_mode "$workdir"' \
      _ "$SMOKE_REPO_ROOT" "$within_root_workdir"
  )"
  smoke_assert_eq "shared" "$mode_within_root" "E3: workdir inside BRIDGE_AGENT_HOME_ROOT (unregistered) remains shared"

  # E4 — v2 ignores explicit per-agent workdir overrides, including a
  # configured path under BRIDGE_AGENT_HOME_ROOT. The configured path is not
  # the dynamic agent's actual workdir, so it remains an ordinary
  # home-root-managed path and resolves as shared.
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "static-agent"
BRIDGE_AGENT_ENGINE["static-agent"]="claude"
BRIDGE_AGENT_SOURCE["static-agent"]="static"
BRIDGE_AGENT_SESSION["static-agent"]="static-agent"
BRIDGE_AGENT_WORKDIR["static-agent"]="$static_configured_workdir"
BRIDGE_AGENT_ISOLATION_MODE["static-agent"]="linux-user"

bridge_add_agent_id_if_missing "dynamic-agent"
BRIDGE_AGENT_ENGINE["dynamic-agent"]="claude"
BRIDGE_AGENT_SOURCE["dynamic-agent"]="dynamic"
BRIDGE_AGENT_SESSION["dynamic-agent"]="dynamic-agent"
BRIDGE_AGENT_WORKDIR["dynamic-agent"]="$dynamic_under_root_configured_workdir"
BRIDGE_AGENT_ISOLATION_MODE["dynamic-agent"]="linux-user"
EOF
  mode_dynamic_under_root_configured="$(
    "$bash4_bin" -c 'repo="$1"; workdir="$2"; source "$repo/bridge-lib.sh"; bridge_load_roster; bridge_claude_settings_mode "$workdir"' \
      _ "$SMOKE_REPO_ROOT" "$dynamic_under_root_configured_workdir"
  )"
  smoke_assert_eq "shared" "$mode_dynamic_under_root_configured" "E4: ignored dynamic workdir override under HOME_ROOT remains shared"
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
  smoke_run "v2 managed static workdir shared settings" managed_v2_workdir_shared_settings
  smoke_run "claude settings mode source=static gate (#516)" claude_settings_mode_source_gate
  smoke_run "hook runtime helper output" hook_runtime_helpers
  smoke_log "passed"
}

main "$@"
