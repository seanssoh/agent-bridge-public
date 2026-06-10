#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="launch"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

write_launch_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/launch-agent"
  local isolated_workdir="$BRIDGE_AGENT_HOME_ROOT/launch-isolated-agent"
  mkdir -p "$workdir" "$isolated_workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "launch-agent"
BRIDGE_AGENT_DESC["launch-agent"]="Launch static smoke"
BRIDGE_AGENT_ENGINE["launch-agent"]="shell"
BRIDGE_AGENT_SESSION["launch-agent"]="launch-smoke-session"
BRIDGE_AGENT_WORKDIR["launch-agent"]="$workdir"
BRIDGE_AGENT_LAUNCH_CMD["launch-agent"]="bash -lc 'echo launch-agent'"
BRIDGE_AGENT_LOOP["launch-agent"]=0
BRIDGE_AGENT_CONTINUE["launch-agent"]=0

bridge_add_agent_id_if_missing "launch-isolated-agent"
BRIDGE_AGENT_DESC["launch-isolated-agent"]="Launch isolated umask smoke"
BRIDGE_AGENT_ENGINE["launch-isolated-agent"]="shell"
BRIDGE_AGENT_SESSION["launch-isolated-agent"]="launch-isolated-smoke-session"
BRIDGE_AGENT_WORKDIR["launch-isolated-agent"]="$isolated_workdir"
BRIDGE_AGENT_LAUNCH_CMD["launch-isolated-agent"]="bash -lc 'echo launch-isolated-agent'"
BRIDGE_AGENT_LOOP["launch-isolated-agent"]=0
BRIDGE_AGENT_CONTINUE["launch-isolated-agent"]=0
BRIDGE_AGENT_ISOLATION_MODE["launch-isolated-agent"]="linux-user"
BRIDGE_AGENT_OS_USER["launch-isolated-agent"]="agent-bridge-launch-smoke"
EOF
}

launch_dry_run_contract() {
  local start_out run_out list_out

  list_out="$(bash "$SMOKE_REPO_ROOT/bridge-start.sh" --list)"
  smoke_assert_contains "$list_out" "launch-agent" "bridge-start --list includes smoke agent"

  start_out="$(bash "$SMOKE_REPO_ROOT/bridge-start.sh" launch-agent --dry-run)"
  smoke_assert_contains "$start_out" "agent=launch-agent" "bridge-start dry-run agent"
  smoke_assert_contains "$start_out" "session=launch-smoke-session" "bridge-start dry-run session"
  smoke_assert_contains "$start_out" "tmux_command=" "bridge-start dry-run tmux command"
  smoke_assert_contains "$start_out" "bridge-run.sh launch-agent --no-continue --once" "bridge-start dry-run run command"

  run_out="$(bash "$SMOKE_REPO_ROOT/bridge-run.sh" launch-agent --dry-run)"
  smoke_assert_contains "$run_out" "agent=launch-agent" "bridge-run dry-run agent"
  smoke_assert_contains "$run_out" "engine=shell" "bridge-run dry-run engine"
  smoke_assert_contains "$run_out" "launch=bash -lc 'echo launch-agent'" "bridge-run dry-run launch command"
}

launch_umask_probe_contract() {
  local shared_probe isolated_probe
  local shared_recorded isolated_recorded
  local v2_data_root

  shared_probe="$SMOKE_TMP_ROOT/launch-v2-shared-umask.probe"
  isolated_probe="$SMOKE_TMP_ROOT/launch-v2-isolated-umask.probe"
  v2_data_root="$SMOKE_TMP_ROOT/v2-data"
  mkdir -p "$v2_data_root/agents" "$v2_data_root/shared" "$v2_data_root/state"

  BRIDGE_LAYOUT=v2 \
  BRIDGE_DATA_ROOT="$v2_data_root" \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  BRIDGE_RUN_UMASK_PROBE_FILE="$shared_probe" \
    bash "$SMOKE_REPO_ROOT/bridge-run.sh" launch-agent --dry-run >/dev/null
  shared_recorded="$(cat "$shared_probe" 2>/dev/null || true)"
  smoke_assert_eq "0077" "$shared_recorded" "v2 shared bridge-run umask remains private"

  BRIDGE_LAYOUT=v2 \
  BRIDGE_DATA_ROOT="$v2_data_root" \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  BRIDGE_RUN_UMASK_PROBE_FILE="$isolated_probe" \
    bash "$SMOKE_REPO_ROOT/bridge-run.sh" launch-isolated-agent --dry-run >/dev/null
  isolated_recorded="$(cat "$isolated_probe" 2>/dev/null || true)"
  smoke_assert_eq "0007" "$isolated_recorded" "v2 linux-user bridge-run umask remains 0007"
}

bun_preflight_harness() {
  local harness="$SMOKE_TMP_ROOT/bun-preflight-harness.sh"

  cat >"$harness" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

AGENT="${BRIDGE_TEST_AGENT:-bun-preflight-agent}"
ENGINE="${BRIDGE_TEST_ENGINE:-claude}"
SAFE_MODE="${BRIDGE_TEST_SAFE_MODE:-0}"

bridge_agent_effective_launch_plugin_channels_csv() {
  printf '%s' "${BRIDGE_TEST_CHANNELS:-}"
}

bridge_trim_whitespace() {
  local value="${1:-}"
  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s' "$value"
}

bridge_plugin_mcp_is_probeable_item() {
  case "${1:-}" in
    plugin:discord|plugin:discord@claude-plugins-official|plugin:teams|plugin:teams@*|plugin:mattermost|plugin:mattermost@*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_resolve_bun_executable() {
  [[ -n "${BRIDGE_TEST_BUN_BIN:-}" ]] || return 1
  printf '%s' "$BRIDGE_TEST_BUN_BIN"
}

bridge_audit_log() {
  printf '%s\n' "$*" >>"${BRIDGE_TEST_AUDIT:?}"
}

log_line() {
  printf '%s\n' "$*" >>"${BRIDGE_TEST_LOG:?}"
}

EOF
  awk '
    /^bridge_run_preflight_plugin_mcp_bun\(\) \{/ { in_fn=1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "$SMOKE_REPO_ROOT/bridge-run.sh" >>"$harness"
  cat >>"$harness" <<'EOF'
bridge_run_preflight_plugin_mcp_bun
EOF
  chmod 0755 "$harness"
  printf '%s' "$harness"
}

bun_preflight_contract() {
  local harness no_bun_path fake_bun log_file audit_file rc out

  harness="$(bun_preflight_harness)"
  no_bun_path="$SMOKE_TMP_ROOT/no-bun-path"
  mkdir -p "$no_bun_path"
  log_file="$SMOKE_TMP_ROOT/bun-preflight.log"
  audit_file="$SMOKE_TMP_ROOT/bun-preflight.audit"

  rc=0
  : >"$log_file"
  : >"$audit_file"
  out="$(BRIDGE_TEST_CHANNELS="plugin:discord@claude-plugins-official" \
    BRIDGE_TEST_LOG="$log_file" \
    BRIDGE_TEST_AUDIT="$audit_file" \
    PATH="$no_bun_path" \
    "$BASH" "$harness" 2>&1)" || rc=$?
  smoke_assert_eq "67" "$rc" "probeable Claude plugin channel fails fast when bun is missing"
  smoke_assert_contains "$(cat "$log_file")" "require bun" "missing-bun preflight logs actionable error"
  smoke_assert_contains "$(cat "$audit_file")" "plugin_mcp_runtime_missing_bun" "missing-bun preflight audits runtime miss"
  smoke_assert_eq "" "$out" "missing-bun harness emits through log_line only"

  rc=0
  : >"$log_file"
  : >"$audit_file"
  BRIDGE_TEST_CHANNELS="plugin:cosmax@marketplace" \
    BRIDGE_TEST_LOG="$log_file" \
    BRIDGE_TEST_AUDIT="$audit_file" \
    PATH="$no_bun_path" \
    "$BASH" "$harness" >/dev/null 2>&1 || rc=$?
  smoke_assert_eq "0" "$rc" "non-probeable plugin channel does not require bun"
  smoke_assert_eq "" "$(cat "$log_file")" "non-probeable plugin preflight stays quiet"

  rc=0
  : >"$log_file"
  : >"$audit_file"
  BRIDGE_TEST_CHANNELS="plugin:discord@claude-plugins-official" \
    BRIDGE_TEST_SAFE_MODE=1 \
    BRIDGE_TEST_LOG="$log_file" \
    BRIDGE_TEST_AUDIT="$audit_file" \
    PATH="$no_bun_path" \
    "$BASH" "$harness" >/dev/null 2>&1 || rc=$?
  smoke_assert_eq "0" "$rc" "safe mode bypasses bun preflight"

  fake_bun="$SMOKE_TMP_ROOT/bin/bun"
  mkdir -p "$(dirname "$fake_bun")"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bun"
  chmod 0755 "$fake_bun"
  rc=0
  : >"$log_file"
  : >"$audit_file"
  BRIDGE_TEST_CHANNELS="plugin:discord@claude-plugins-official" \
    BRIDGE_TEST_BUN_BIN="$fake_bun" \
    BRIDGE_TEST_LOG="$log_file" \
    BRIDGE_TEST_AUDIT="$audit_file" \
    PATH="$no_bun_path" \
    "$BASH" "$harness" >/dev/null 2>&1 || rc=$?
  smoke_assert_eq "0" "$rc" "probeable plugin channel passes when bun is resolvable"
}

bun_preflight_call_order_contract() {
  python3 - "$SMOKE_REPO_ROOT/bridge-run.sh" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
loop = text.index("while true; do")
block_start = text.index('if [[ "$ENGINE" == "claude" && $SAFE_MODE -eq 0 ]]; then', loop)
block_end = text.index("bridge_run_ensure_claude_launch_channel_plugins", block_start)
block = text[block_start:block_end]
preflight = block.index("bridge_run_preflight_plugin_mcp_bun")
sync = block.index("bridge_run_sync_dev_plugin_cache")
if preflight > sync:
    raise SystemExit("bun preflight must run before plugin cache sync")
PY
}

restart_full_preflight_harness() {
  local harness="$SMOKE_TMP_ROOT/restart-full-preflight-harness.sh"

  cat >"$harness" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

bridge_agent_engine() {
  printf '%s' "${BRIDGE_TEST_ENGINE:-claude}"
}

bridge_agent_channels_csv() {
  printf '%s' "${BRIDGE_TEST_CHANNELS:-}"
}

bridge_agent_effective_launch_plugin_channels_csv() {
  printf '%s' "${BRIDGE_TEST_LAUNCH_CHANNELS:-${BRIDGE_TEST_CHANNELS:-}}"
}

bridge_trim_whitespace() {
  local value="${1:-}"
  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s' "$value"
}

bridge_qualify_channel_item() {
  case "${1:-}" in
    plugin:discord) printf '%s' "plugin:discord@claude-plugins-official" ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

bridge_plugin_mcp_is_probeable_item() {
  case "${1:-}" in
    plugin:discord|plugin:discord@claude-plugins-official|plugin:teams|plugin:teams@*|plugin:mattermost|plugin:mattermost@*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_resolve_bun_executable() {
  [[ -n "${BRIDGE_TEST_BUN_BIN:-}" ]] || return 1
  printf '%s' "$BRIDGE_TEST_BUN_BIN"
}

bridge_resolve_engine_binary() {
  printf '%s' "${BRIDGE_TEST_ENGINE_BIN:-/bin/sh}"
}

bridge_isolation_disabled_by_env() {
  return 0
}

bridge_agent_linux_user_isolation_effective() {
  return 1
}

EOF
  awk '
    /^bridge_agent_restart_preflight_full_reason\(\) \{/ { in_fn=1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "$SMOKE_REPO_ROOT/lib/bridge-agents.sh" >>"$harness"
  cat >>"$harness" <<'EOF'
bridge_agent_restart_preflight_full_reason "${BRIDGE_TEST_AGENT:-restart-bun-agent}"
EOF
  chmod 0755 "$harness"
  printf '%s' "$harness"
}

restart_bun_preflight_contract() {
  local harness fake_bun reason

  harness="$(restart_full_preflight_harness)"

  reason="$(BRIDGE_TEST_CHANNELS="plugin:discord@claude-plugins-official" \
    "$BASH" "$harness")"
  smoke_assert_contains "$reason" "plugin-mcp-runtime-missing: bun not resolvable" "restart full preflight blocks missing bun before kill"
  smoke_assert_contains "$reason" "plugin:discord@claude-plugins-official" "restart full preflight names affected channel"

  reason="$(BRIDGE_TEST_CHANNELS="plugin:cosmax@marketplace" \
    "$BASH" "$harness")"
  smoke_assert_eq "" "$reason" "restart full preflight ignores non-probeable plugin channels"

  fake_bun="$SMOKE_TMP_ROOT/bin/bun"
  mkdir -p "$(dirname "$fake_bun")"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bun"
  chmod 0755 "$fake_bun"
  reason="$(BRIDGE_TEST_CHANNELS="plugin:discord@claude-plugins-official" \
    BRIDGE_TEST_BUN_BIN="$fake_bun" \
    "$BASH" "$harness")"
  smoke_assert_eq "" "$reason" "restart full preflight passes when bun is resolvable"
}

main() {
  smoke_setup_bridge_home "launch"
  write_launch_roster
  smoke_run "bridge-start/bridge-run dry-run launch contract" launch_dry_run_contract
  smoke_run "bridge-run linux-user umask probe contract" launch_umask_probe_contract
  smoke_run "bridge-run Claude plugin bun preflight" bun_preflight_contract
  smoke_run "bridge-run bun preflight precedes plugin sync" bun_preflight_call_order_contract
  smoke_run "restart full preflight blocks missing bun before kill" restart_bun_preflight_contract
  smoke_log "passed"
}

main "$@"
