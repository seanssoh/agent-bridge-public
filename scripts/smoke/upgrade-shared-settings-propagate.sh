#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="upgrade-shared-settings-propagate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

json_field() {
  local json="$1"
  local expr="$2"
  printf '%s' "$json" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
expr = sys.argv[1]
print(eval(expr, {"payload": payload}))
' "$expr"
}

settings_value() {
  local settings_file="$1"
  local key="$2"
  python3 - "$settings_file" "$key" <<'PY'
import json
import sys
from pathlib import Path

settings_file, key = sys.argv[1:]
payload = json.loads(Path(settings_file).read_text(encoding="utf-8"))
print(payload.get(key))
PY
}

write_fixture() {
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/patch"

  mkdir -p "$agent_home/.claude" "$BRIDGE_ACTIVE_AGENT_DIR"
  printf '# patch soul\n' >"$agent_home/SOUL.md"
  printf '# Session Type\n\n- Session Type: admin\n' >"$agent_home/SESSION-TYPE.md"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"old"}]}]},"env":{"BASE_ONLY":"yes"}}' >"$agent_home/.claude/settings.json"
  printf '%s\n' '{"env":{"OVERLAY_ONLY":"yes"}}' >"$BRIDGE_AGENT_HOME_ROOT/.claude/settings.local.json"

  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID=patch
bridge_add_agent_id_if_missing "patch"
BRIDGE_AGENT_DESC["patch"]="patch admin role"
BRIDGE_AGENT_ENGINE["patch"]="claude"
BRIDGE_AGENT_SOURCE["patch"]="static"
BRIDGE_AGENT_SESSION["patch"]="patch"
BRIDGE_AGENT_WORKDIR["patch"]="$agent_home"
BRIDGE_AGENT_LOOP["patch"]="1"
BRIDGE_AGENT_CONTINUE["patch"]="1"
EOF
}

assert_dry_run_reports_missing_default() {
  local output count status key

  output="$(BRIDGE_HOME="$BRIDGE_HOME" "$SMOKE_REPO_ROOT/agent-bridge" agent rerender-settings --json)"
  count="$(json_field "$output" 'payload["count"]')"
  status="$(json_field "$output" 'payload["candidates"][0]["status"]')"
  key="$(json_field "$output" 'payload["candidates"][0]["changes"][0]["key"]')"

  smoke_assert_eq "1" "$count" "rerender dry-run target count"
  smoke_assert_eq "needs-rerender" "$status" "rerender dry-run status"
  smoke_assert_eq "autoCompactWindow" "$key" "rerender dry-run missing managed default"
  [[ ! -L "$BRIDGE_AGENT_HOME_ROOT/patch/.claude/settings.json" ]] || smoke_fail "dry-run should not relink settings"
}

assert_apply_rerenders_and_preserves_overlay() {
  local output status audit settings_file effective_file

  output="$(BRIDGE_HOME="$BRIDGE_HOME" "$SMOKE_REPO_ROOT/agent-bridge" agent rerender-settings --apply --json)"
  status="$(json_field "$output" 'payload["candidates"][0]["status"]')"
  smoke_assert_eq "rerendered" "$status" "rerender apply status"

  settings_file="$BRIDGE_AGENT_HOME_ROOT/patch/.claude/settings.json"
  effective_file="$BRIDGE_AGENT_HOME_ROOT/.claude/settings.effective.json"
  [[ -L "$settings_file" ]] || smoke_fail "rerender apply should link agent settings to shared effective settings"
  smoke_assert_eq "400000" "$(settings_value "$settings_file" autoCompactWindow)" "rerender apply backfills autoCompactWindow"
  smoke_assert_eq "yes" "$(python3 - "$settings_file" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("env", {}).get("OVERLAY_ONLY"))
PY
)" "rerender apply preserves operator overlay"
  smoke_assert_eq "400000" "$(settings_value "$effective_file" autoCompactWindow)" "shared effective has managed default"

  audit="$(cat "$BRIDGE_AUDIT_LOG")"
  smoke_assert_contains "$audit" "shared_settings_rerendered" "rerender apply emits audit row"
}

assert_upgrade_runs_rerender() {
  local agent_home upgrade_json has_patch

  agent_home="$BRIDGE_AGENT_HOME_ROOT/patch"
  rm -f "$agent_home/.claude/settings.json" "$BRIDGE_AGENT_HOME_ROOT/.claude/settings.effective.json"
  printf '%s\n' '{"env":{"BASE_ONLY":"yes-again"}}' >"$agent_home/.claude/settings.json"

  upgrade_json="$(
    env BRIDGE_HOME="$BRIDGE_HOME" "$SMOKE_REPO_ROOT/agent-bridge" upgrade \
      --source "$SMOKE_REPO_ROOT" \
      --target "$BRIDGE_HOME" \
      --channel current \
      --no-pull \
      --no-backup \
      --no-migrate-agents \
      --no-restart-daemon \
      --no-restart-agents \
      --allow-dirty \
      --allow-dirty-source \
      --json
  )"
  has_patch="$(json_field "$upgrade_json" 'any(item["agent"] == "patch" for item in payload["shared_settings_rerender"]["candidates"])')"
  smoke_assert_eq "True" "$has_patch" "upgrade reports patch shared settings rerender target"
  [[ -L "$agent_home/.claude/settings.json" ]] || smoke_fail "upgrade should relink managed Claude settings"
  smoke_assert_eq "400000" "$(settings_value "$agent_home/.claude/settings.json" autoCompactWindow)" "upgrade backfills autoCompactWindow"
}

assert_operator_overlay_wins() {
  local agent_home output status

  agent_home="$BRIDGE_AGENT_HOME_ROOT/patch"
  rm -f "$agent_home/.claude/settings.json" "$BRIDGE_AGENT_HOME_ROOT/.claude/settings.effective.json"
  printf '%s\n' '{"autoCompactWindow":600000,"env":{"OVERLAY_ONLY":"yes"}}' >"$BRIDGE_AGENT_HOME_ROOT/.claude/settings.local.json"
  printf '%s\n' '{"env":{"STALE_AGENT":"yes"}}' >"$agent_home/.claude/settings.json"

  output="$(BRIDGE_HOME="$BRIDGE_HOME" "$SMOKE_REPO_ROOT/agent-bridge" agent rerender-settings --apply --json)"
  status="$(json_field "$output" 'payload["candidates"][0]["status"]')"
  smoke_assert_eq "rerendered" "$status" "rerender overlay apply status"
  smoke_assert_eq "600000" "$(settings_value "$agent_home/.claude/settings.json" autoCompactWindow)" "operator overlay overrides managed default"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "upgrade-settings"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/.claude"
  write_fixture
  smoke_run "rerender dry-run reports missing managed default" assert_dry_run_reports_missing_default
  smoke_run "rerender apply links shared settings and audits" assert_apply_rerenders_and_preserves_overlay
  smoke_run "upgrade apply rerenders shared Claude settings" assert_upgrade_runs_rerender
  smoke_run "operator overlay wins over managed default" assert_operator_overlay_wins
  smoke_log "passed"
}

main "$@"
