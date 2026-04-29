#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="upgrade-source-preservation"
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
  python3 - "$json" "$expr" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expr = sys.argv[2]
print(eval(expr, {"payload": payload}))
PY
}

agent_source() {
  local agent="$1"
  BRIDGE_HOME="$BRIDGE_HOME" "$SMOKE_REPO_ROOT/agent-bridge" agent show "$agent" --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["source"])'
}

agent_admin_flag() {
  local agent="$1"
  BRIDGE_HOME="$BRIDGE_HOME" "$SMOKE_REPO_ROOT/agent-bridge" agent show "$agent" --json \
    | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin)["admin"] else "no")'
}

write_fixture() {
  local patch_home="$BRIDGE_AGENT_HOME_ROOT/patch"
  local worker_home="$SMOKE_TMP_ROOT/dynamic-worker"

  mkdir -p "$patch_home" "$worker_home" "$BRIDGE_ACTIVE_AGENT_DIR"
  printf '# patch soul\n' >"$patch_home/SOUL.md"
  printf '# Session Type\n\n- Session Type: admin\n- Onboarding State: complete\n' >"$patch_home/SESSION-TYPE.md"
  printf '# worker\n' >"$worker_home/README.md"

  cat >"$BRIDGE_ACTIVE_AGENT_DIR/patch.env" <<EOF
AGENT_ID=patch
AGENT_DESC=patch\ admin\ role
AGENT_ENGINE=claude
AGENT_SESSION=patch
AGENT_WORKDIR=$patch_home
AGENT_LOOP=1
AGENT_CONTINUE=1
EOF

  cat >"$BRIDGE_ACTIVE_AGENT_DIR/dynamic-worker.env" <<EOF
AGENT_ID=dynamic-worker
AGENT_DESC=dynamic\ worker
AGENT_ENGINE=claude
AGENT_SESSION=dynamic-worker
AGENT_WORKDIR=$worker_home
AGENT_LOOP=1
AGENT_CONTINUE=1
EOF
}

assert_reclassify_dry_run() {
  local output count agent old_source action

  output="$(BRIDGE_HOME="$BRIDGE_HOME" "$SMOKE_REPO_ROOT/agent-bridge" agent reclassify --json)"
  count="$(json_field "$output" 'payload["count"]')"
  agent="$(json_field "$output" 'payload["candidates"][0]["agent"]')"
  old_source="$(json_field "$output" 'payload["candidates"][0]["old_source"]')"
  action="$(json_field "$output" 'payload["candidates"][0]["action"]')"

  smoke_assert_eq "1" "$count" "reclassify dry-run candidate count"
  smoke_assert_eq "patch" "$agent" "reclassify dry-run candidate agent"
  smoke_assert_eq "dynamic" "$old_source" "reclassify dry-run preserves observed old source"
  smoke_assert_eq "reclassify" "$action" "reclassify dry-run action"
  smoke_assert_eq "dynamic" "$(agent_source patch)" "dry-run leaves patch source unchanged"
}

assert_reclassify_apply() {
  local output count action audit

  output="$(BRIDGE_HOME="$BRIDGE_HOME" "$SMOKE_REPO_ROOT/agent-bridge" agent reclassify --apply --json)"
  count="$(json_field "$output" 'payload["count"]')"
  action="$(json_field "$output" 'payload["candidates"][0]["action"]')"
  audit="$(cat "$BRIDGE_AUDIT_LOG")"

  smoke_assert_eq "1" "$count" "reclassify apply candidate count"
  smoke_assert_eq "reclassify" "$action" "reclassify apply action"
  smoke_assert_eq "static" "$(agent_source patch)" "apply restores admin source to static"
  smoke_assert_eq "yes" "$(agent_admin_flag patch)" "apply restores admin identity when roster scalar is missing"
  smoke_assert_eq "dynamic" "$(agent_source dynamic-worker)" "apply preserves unrelated dynamic agent source"
  smoke_assert_contains "$audit" "agent_source_reclassified" "apply emits audit row"
  smoke_assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" 'BRIDGE_AGENT_SOURCE["patch"]="static"' "apply persists static source"
  smoke_assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_ADMIN_AGENT_ID=patch" "apply persists admin scalar"
}

assert_upgrade_runs_fixup() {
  local upgrade_json count

  rm -f "$BRIDGE_ROSTER_LOCAL_FILE"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  smoke_assert_eq "dynamic" "$(agent_source patch)" "fixture reset exposes patch as dynamic"

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
  count="$(json_field "$upgrade_json" 'payload["source_reclassify"]["count"]')"
  smoke_assert_eq "1" "$count" "upgrade apply reports source reclassify candidate"
  smoke_assert_eq "static" "$(agent_source patch)" "upgrade apply restores admin source to static"
  smoke_assert_eq "yes" "$(agent_admin_flag patch)" "upgrade apply restores admin identity"
  smoke_assert_eq "dynamic" "$(agent_source dynamic-worker)" "upgrade apply preserves dynamic worker"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "upgrade-source"
  write_fixture
  smoke_run "reclassify dry-run detects static-admin misclassification" assert_reclassify_dry_run
  smoke_run "reclassify apply restores static source and audits" assert_reclassify_apply
  smoke_run "upgrade apply runs source reclassify fixup" assert_upgrade_runs_fixup
  smoke_log "passed"
}

main "$@"
