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
  # Issue #555: rerender writes per-agent effective file under each
  # agent's workdir, not the install-wide path; the workdir symlink
  # points to that per-agent file.
  effective_file="$BRIDGE_AGENT_HOME_ROOT/patch/.claude/settings.effective.json"
  [[ -L "$settings_file" ]] || smoke_fail "rerender apply should link agent settings to per-agent effective settings"
  # Issue #570: managed autoCompactWindow default is unconditionally 1_000_000.
  smoke_assert_eq "1000000" "$(settings_value "$settings_file" autoCompactWindow)" "rerender apply backfills autoCompactWindow"
  smoke_assert_eq "yes" "$(python3 - "$settings_file" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("env", {}).get("OVERLAY_ONLY"))
PY
)" "rerender apply preserves operator overlay"
  smoke_assert_eq "1000000" "$(settings_value "$effective_file" autoCompactWindow)" "per-agent effective has managed default"

  audit="$(cat "$BRIDGE_AUDIT_LOG")"
  smoke_assert_contains "$audit" "shared_settings_rerendered" "rerender apply emits audit row"
}

assert_upgrade_runs_rerender() {
  local agent_home upgrade_json has_patch

  agent_home="$BRIDGE_AGENT_HOME_ROOT/patch"
  # Issue #555: per-agent effective file lives under <agent>/.claude/.
  rm -f "$agent_home/.claude/settings.json" "$agent_home/.claude/settings.effective.json"
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
  # Issue #570: managed autoCompactWindow default is unconditionally 1_000_000.
  smoke_assert_eq "1000000" "$(settings_value "$agent_home/.claude/settings.json" autoCompactWindow)" "upgrade backfills autoCompactWindow"
}

assert_operator_overlay_wins() {
  local agent_home output status

  agent_home="$BRIDGE_AGENT_HOME_ROOT/patch"
  # Issue #555: per-agent effective file lives under <agent>/.claude/.
  rm -f "$agent_home/.claude/settings.json" "$agent_home/.claude/settings.effective.json"
  printf '%s\n' '{"autoCompactWindow":600000,"env":{"OVERLAY_ONLY":"yes"}}' >"$BRIDGE_AGENT_HOME_ROOT/.claude/settings.local.json"
  printf '%s\n' '{"env":{"STALE_AGENT":"yes"}}' >"$agent_home/.claude/settings.json"

  output="$(BRIDGE_HOME="$BRIDGE_HOME" "$SMOKE_REPO_ROOT/agent-bridge" agent rerender-settings --apply --json)"
  status="$(json_field "$output" 'payload["candidates"][0]["status"]')"
  smoke_assert_eq "rerendered" "$status" "rerender overlay apply status"
  smoke_assert_eq "600000" "$(settings_value "$agent_home/.claude/settings.json" autoCompactWindow)" "operator overlay overrides managed default"
}

assert_stop_hook_suite_propagates() {
  # Issue #541 PR-B: ensure-stop-hook on the shared base must register the
  # full suite (mark-idle.sh + surface-reply-enforce.py + session-stop.py),
  # and the rendered effective settings (consumed by every per-agent symlink
  # via bridge_link_claude_settings_to_shared) must carry all three.
  local base effective stop_count
  local has_mark_idle has_surface has_session_stop

  base="$BRIDGE_AGENT_HOME_ROOT/.claude/settings.json"
  effective="$BRIDGE_AGENT_HOME_ROOT/.claude/settings.effective.json"

  # Reset the shared base and overlay to a "pre-fix" shape: only
  # mark-idle.sh registered, mirroring v0.7.3 reference install state.
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/.claude"
  rm -f "$BRIDGE_AGENT_HOME_ROOT/.claude/settings.local.json" "$effective"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash ~/.agent-bridge/hooks/mark-idle.sh","timeout":3,"additionalContext":true}]}]}}' >"$base"

  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-stop-hook \
    --settings-file "$base" \
    --bridge-home "$BRIDGE_HOME" \
    --bash-bin bash >/dev/null

  stop_count="$(python3 - "$base" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
stop = data.get("hooks", {}).get("Stop", [])
flat = [h.get("command","") for grp in stop for h in grp.get("hooks", [])]
print(len(flat))
PY
)"
  smoke_assert_eq "3" "$stop_count" "shared base Stop array has 3 entries after ensure-stop-hook"

  has_mark_idle="$(python3 - "$base" mark-idle.sh <<'PY'
import json, sys
from pathlib import Path
needle = sys.argv[2]
data = json.loads(Path(sys.argv[1]).read_text())
stop = data.get("hooks", {}).get("Stop", [])
flat = [h.get("command","") for grp in stop for h in grp.get("hooks", [])]
print("yes" if any(needle in c for c in flat) else "no")
PY
)"
  has_surface="$(python3 - "$base" surface-reply-enforce.py <<'PY'
import json, sys
from pathlib import Path
needle = sys.argv[2]
data = json.loads(Path(sys.argv[1]).read_text())
stop = data.get("hooks", {}).get("Stop", [])
flat = [h.get("command","") for grp in stop for h in grp.get("hooks", [])]
print("yes" if any(needle in c for c in flat) else "no")
PY
)"
  has_session_stop="$(python3 - "$base" session-stop.py <<'PY'
import json, sys
from pathlib import Path
needle = sys.argv[2]
data = json.loads(Path(sys.argv[1]).read_text())
stop = data.get("hooks", {}).get("Stop", [])
flat = [h.get("command","") for grp in stop for h in grp.get("hooks", [])]
print("yes" if any(needle in c for c in flat) else "no")
PY
)"
  smoke_assert_eq "yes" "$has_mark_idle" "shared base Stop suite includes mark-idle.sh"
  smoke_assert_eq "yes" "$has_surface" "shared base Stop suite includes surface-reply-enforce.py"
  smoke_assert_eq "yes" "$has_session_stop" "shared base Stop suite includes session-stop.py"

  # status-stop-hook must agree (suite present, exit 0)
  local status_out
  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-stop-hook --settings-file "$base" --bridge-home "$BRIDGE_HOME" --bash-bin bash --format shell)"
  smoke_assert_contains "$status_out" "HOOK_STOP_HOOK_SUITE=present" "status-stop-hook reports suite present"
  smoke_assert_contains "$status_out" "HOOK_STOP_HOOK_SURFACE_REPLY_ENFORCE=present" "status-stop-hook reports surface-reply-enforce.py present"
  smoke_assert_contains "$status_out" "HOOK_STOP_HOOK_SESSION_STOP=present" "status-stop-hook reports session-stop.py present"

  # render-shared-settings must propagate the suite into the effective file
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$base" \
    --overlay-settings-file "$BRIDGE_AGENT_HOME_ROOT/.claude/settings.local.json" \
    --effective-settings-file "$effective" >/dev/null

  local effective_count
  effective_count="$(python3 - "$effective" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
stop = data.get("hooks", {}).get("Stop", [])
flat = [h.get("command","") for grp in stop for h in grp.get("hooks", [])]
print(len(flat))
PY
)"
  smoke_assert_eq "3" "$effective_count" "effective settings carries 3-entry Stop suite (rerender-consumed)"
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
  smoke_run "Stop hook suite propagates from shared base (#541 PR-B)" assert_stop_hook_suite_propagates
  smoke_log "passed"
}

main "$@"
