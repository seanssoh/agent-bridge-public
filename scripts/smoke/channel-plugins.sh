#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="channel-plugins"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

json_value() {
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = payload
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

channel_shared_overlay() {
  local overlay effective telegram discord first second

  bash "$SMOKE_REPO_ROOT/scripts/apply-channel-policy.sh" --quiet
  overlay="$BRIDGE_AGENT_HOME_ROOT/.claude/settings.local.json"
  effective="$BRIDGE_AGENT_HOME_ROOT/.claude/settings.effective.json"
  smoke_assert_file_exists "$overlay" "channel policy shared overlay"
  smoke_assert_file_exists "$effective" "channel policy effective settings"

  telegram="$(json_value "$overlay" "enabledPlugins.telegram@claude-plugins-official")"
  discord="$(json_value "$overlay" "enabledPlugins.discord@claude-plugins-official")"
  smoke_assert_eq "False" "$telegram" "shared overlay disables Telegram singleton"
  smoke_assert_eq "False" "$discord" "shared overlay disables Discord singleton"

  first="$(cat "$overlay")"
  bash "$SMOKE_REPO_ROOT/scripts/apply-channel-policy.sh" --quiet
  second="$(cat "$overlay")"
  smoke_assert_eq "$first" "$second" "channel policy shared overlay idempotence"
}

channel_admin_bypass() {
  local overlay telegram discord

  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/admin/.claude"
  env BRIDGE_ADMIN_AGENT_ID=admin bash "$SMOKE_REPO_ROOT/scripts/apply-channel-policy.sh" --quiet
  overlay="$BRIDGE_AGENT_HOME_ROOT/admin/.claude/settings.local.json"
  smoke_assert_file_exists "$overlay" "admin channel policy overlay"

  telegram="$(json_value "$overlay" "enabledPlugins.telegram@claude-plugins-official")"
  discord="$(json_value "$overlay" "enabledPlugins.discord@claude-plugins-official")"
  smoke_assert_eq "True" "$telegram" "admin overlay re-enables Telegram singleton"
  smoke_assert_eq "True" "$discord" "admin overlay re-enables Discord singleton"
}

channel_owner_bypass() {
  local overlay telegram discord

  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/dev-discord/.claude" "$BRIDGE_AGENT_HOME_ROOT/dev-teams/.claude"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<'EOF'
BRIDGE_AGENT_CHANNELS["dev-discord"]="plugin:discord@claude-plugins-official"
BRIDGE_AGENT_CHANNELS["dev-teams"]="plugin:teams@agent-bridge"
EOF

  bash "$SMOKE_REPO_ROOT/scripts/apply-channel-policy.sh" --quiet
  overlay="$BRIDGE_AGENT_HOME_ROOT/dev-discord/.claude/settings.local.json"
  smoke_assert_file_exists "$overlay" "per-agent singleton owner overlay"
  discord="$(json_value "$overlay" "enabledPlugins.discord@claude-plugins-official")"
  smoke_assert_eq "True" "$discord" "per-agent owner overlay re-enables owned Discord singleton"

  if [[ -f "$BRIDGE_AGENT_HOME_ROOT/dev-teams/.claude/settings.local.json" ]]; then
    telegram="$(cat "$BRIDGE_AGENT_HOME_ROOT/dev-teams/.claude/settings.local.json")"
    smoke_assert_not_contains "$telegram" "telegram@claude-plugins-official" "non-singleton channel owner should not receive singleton bypass"
  fi
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "channel-plugins"
  smoke_run "shared singleton-disable overlay" channel_shared_overlay
  smoke_run "admin singleton bypass overlay" channel_admin_bypass
  smoke_run "per-agent singleton owner bypass" channel_owner_bypass
  smoke_log "passed"
}

main "$@"
