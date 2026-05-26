#!/usr/bin/env bash
# scripts/smoke/γ-cli-consistency.sh — v0.15.0-beta2 Lane γ.
#
# Closes:
#   #1232 — `setup teams <agent>` must NOT walk the entire channel set
#           to validate plugin readiness. A foreign-marketplace channel
#           declared on the same agent (e.g. `plugin:cosmax-ep-approval
#           @cosmax-marketplace`) must not make `setup teams` exit
#           non-zero. Plugin readiness for unrelated channels is the
#           job of `agent start`.
#   #1235 — `agent update --channels <csv>` is accepted as an alias for
#           `--channels-set`; un-suffixed shorthand is auto-qualified
#           via the canonical built-in marketplace table (matching the
#           create-side `--channels` semantics introduced in #1221);
#           `--dangerously-load-development-channels` flags in
#           launch_cmd are automatically reconciled against the new
#           channel set so stale dev-channel tokens cannot survive a
#           channel-set update.
#   #1236 — `agent update --help` short-circuits to usage before the
#           positional <agent> binding (the universal help gate in
#           scripts/smoke/1117-cli-help-universal-gate.sh now expects
#           the verb to pass; this smoke asserts the runtime behavior
#           with explicit text checks too).
#
# The Python wizard half of `setup teams` is not exercised here — that
# path needs real Microsoft Teams app credentials. We instead unit-test
# the target-scoped readiness helper directly so the regression is
# caught without a network round-trip.

set -euo pipefail

SMOKE_NAME="γ-cli-consistency"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

ADMIN="testadmin"
WORKER="testworker"

write_roster_fixture() {
  # Seed agent-roster.local.sh with admin + worker. The worker carries a
  # legacy channel list that intentionally mixes builtin
  # (plugin:teams@agent-bridge) and foreign-marketplace
  # (plugin:cosmax-ep-approval@cosmax-marketplace) channels — exactly
  # the #1232 repro shape.
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID=${ADMIN}
# BEGIN AGENT BRIDGE MANAGED ROLE: ${ADMIN}
bridge_add_agent_id_if_missing ${ADMIN}
BRIDGE_AGENT_DESC["${ADMIN}"]='admin role'
BRIDGE_AGENT_ENGINE["${ADMIN}"]='claude'
BRIDGE_AGENT_SESSION["${ADMIN}"]='${ADMIN}'
BRIDGE_AGENT_WORKDIR["${ADMIN}"]='${BRIDGE_AGENT_HOME_ROOT}/${ADMIN}'
BRIDGE_AGENT_SOURCE["${ADMIN}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${ADMIN}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${ADMIN}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${ADMIN}

# BEGIN AGENT BRIDGE MANAGED ROLE: ${WORKER}
bridge_add_agent_id_if_missing ${WORKER}
BRIDGE_AGENT_DESC["${WORKER}"]='worker role'
BRIDGE_AGENT_ENGINE["${WORKER}"]='claude'
BRIDGE_AGENT_SESSION["${WORKER}"]='${WORKER}'
BRIDGE_AGENT_WORKDIR["${WORKER}"]='${BRIDGE_AGENT_HOME_ROOT}/${WORKER}'
BRIDGE_AGENT_SOURCE["${WORKER}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${WORKER}"]='claude --dangerously-skip-permissions --dangerously-load-development-channels plugin:teams@agent-bridge --dangerously-load-development-channels plugin:ms365@agent-bridge --dangerously-load-development-channels plugin:cosmax-ep-approval@cosmax-marketplace'
BRIDGE_AGENT_CHANNELS["${WORKER}"]='plugin:teams@agent-bridge,plugin:ms365@agent-bridge,plugin:cosmax-ep-approval@cosmax-marketplace'
BRIDGE_AGENT_CONTINUE["${WORKER}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${WORKER}
EOF
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$WORKER" "$BRIDGE_AGENT_HOME_ROOT/$ADMIN"
}

# --- #1232 assertions --------------------------------------------------------

_helper_probe_script() {
  # Emit the inline driver to a file, then exec it. Avoids the nested
  # `bash -c '...'` heredoc quoting trap (a leading `cat <<EOF` inside
  # the outer `bash -c` body was eating subsequent commands when this
  # smoke ran under the operator's parent shell environment).
  local agent="$1"
  local needle="$2"
  local script_path="$SMOKE_TMP_ROOT/helper-probe.sh"
  cat >"$script_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$SMOKE_REPO_ROOT/bridge-lib.sh"
bridge_load_roster
source "$SMOKE_REPO_ROOT/bridge-setup.sh" >/dev/null 2>&1 || true
# Stub AFTER sourcing so the redefinition wins over the lib version
# bridge-setup.sh just pulled in via bridge-agents.sh.
bridge_ensure_claude_channel_plugins_for_csv() {
  printf "WALKER_CSV=%s\\n" "\$1"
}
bridge_ensure_claude_plugin_enabled() {
  # Safety net: a regression that bypasses the function-level stub
  # above (e.g. by inlining the walker) would land here instead.
  printf "BYPASSED_STUB_FOR=%s\\n" "\$1"
}
bridge_setup_ensure_claude_channel_plugin_for_needle "$agent" "$needle"
EOF
  bash "$script_path"
}

assert_target_scoped_helper_only_walks_needle() {
  # Source the bridge libraries and call the helper directly. The helper
  # must select ONLY the matching channel from the agent's CSV and
  # delegate to bridge_ensure_claude_channel_plugins_for_csv with that
  # single-item subset.
  write_roster_fixture
  local recorded_csv
  recorded_csv="$(_helper_probe_script "$WORKER" "plugin:teams")"

  smoke_assert_contains "$recorded_csv" "WALKER_CSV=plugin:teams@agent-bridge" \
    "#1232 helper passes ONLY plugin:teams to readiness walker"
  smoke_assert_not_contains "$recorded_csv" "ms365" \
    "#1232 helper must NOT include unrelated ms365 channel"
  smoke_assert_not_contains "$recorded_csv" "cosmax-ep-approval" \
    "#1232 helper must NOT include foreign-marketplace channel"
}

assert_target_scoped_helper_handles_pre_qualified_match() {
  # Pre-qualified channel in the agent's CSV (plugin:teams@<other>) must
  # still match the un-suffixed needle. Operator may have pinned a
  # non-default marketplace; the verb still owns its plugin selector.
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID=${ADMIN}
BRIDGE_AGENT_ENGINE["${WORKER}"]='claude'
BRIDGE_AGENT_WORKDIR["${WORKER}"]='${BRIDGE_AGENT_HOME_ROOT}/${WORKER}'
BRIDGE_AGENT_SOURCE["${WORKER}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${WORKER}"]='claude'
BRIDGE_AGENT_CHANNELS["${WORKER}"]='plugin:teams@cosmax-marketplace,plugin:ms365@agent-bridge'
bridge_add_agent_id_if_missing ${WORKER}
EOF

  local recorded_csv
  recorded_csv="$(_helper_probe_script "$WORKER" "plugin:teams")"

  smoke_assert_contains "$recorded_csv" "plugin:teams@cosmax-marketplace" \
    "#1232 helper preserves operator-pinned marketplace on selector match"
  smoke_assert_not_contains "$recorded_csv" "ms365" \
    "#1232 helper still excludes unrelated channels when needle is plugin:teams"
}

# --- #1235 assertions --------------------------------------------------------

run_update() {
  BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_AGENT_ID="$ADMIN" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" update "$WORKER" --json "$@"
}

read_field() {
  local key="$1"
  grep "^${key}\\[\"${WORKER}\"\\]=" "$BRIDGE_ROSTER_LOCAL_FILE" | head -n 1
}

assert_channels_alias_accepted() {
  write_roster_fixture
  # `agent update --channels` (alias of --channels-set) accepts un-suffixed
  # shorthand identical to create-side `agent create --channels`.
  local output
  output="$(run_update --channels "plugin:teams,plugin:ms365")"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
after = payload["after"]["channels"]
# Auto-suffix: both tokens must end up @agent-bridge per the canonical table.
assert "plugin:teams@agent-bridge" in after, f"missing teams@agent-bridge in {after}"
assert "plugin:ms365@agent-bridge" in after, f"missing ms365@agent-bridge in {after}"
# Foreign-marketplace channel (cosmax-ep-approval) must be DROPPED by the
# full-replace.
assert "cosmax-ep-approval" not in after, f"foreign channel survived full set: {after}"
' "$output"
}

assert_channels_set_alias_normalization() {
  # `--channels-set` should also auto-suffix shorthand (the #1235 gap (2)
  # was that the update-side validator rejected un-qualified tokens
  # while the create-side accepted them).
  write_roster_fixture
  local output
  output="$(run_update --channels-set "plugin:teams")"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
after = payload["after"]["channels"]
assert after == "plugin:teams@agent-bridge", f"expected plugin:teams@agent-bridge, got {after}"
' "$output"
}

assert_launch_cmd_reconcile_remove_stale() {
  # Channel-set update drops a dev-channel from BRIDGE_AGENT_CHANNELS;
  # the matching --dangerously-load-development-channels token in
  # launch_cmd must be removed automatically (#1235 gap (3)). Before
  # this fix, the operator had to chase each orphan with a second pass.
  write_roster_fixture

  # Pre-condition sanity: roster line has all three dev-channels.
  local before_launch
  before_launch="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"
  smoke_assert_contains "$before_launch" "plugin:teams@agent-bridge" \
    "before: roster launch_cmd has plugin:teams token"
  smoke_assert_contains "$before_launch" "plugin:ms365@agent-bridge" \
    "before: roster launch_cmd has plugin:ms365 token"
  smoke_assert_contains "$before_launch" "plugin:cosmax-ep-approval@cosmax-marketplace" \
    "before: roster launch_cmd has foreign-marketplace token"

  local output
  output="$(run_update --channels-set "plugin:ms365@agent-bridge")"

  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
after_launch = payload["after"]["launch_cmd"]
after_channels = payload["after"]["channels"]
assert after_channels == "plugin:ms365@agent-bridge", f"channels after={after_channels}"
# Only the ms365 dev-channel token should remain in launch_cmd.
assert "plugin:ms365@agent-bridge" in after_launch, f"ms365 token missing: {after_launch}"
# Stale teams + foreign tokens MUST be gone.
assert "plugin:teams@agent-bridge" not in after_launch, f"stale teams token survived: {after_launch}"
assert "cosmax-ep-approval" not in after_launch, f"stale foreign token survived: {after_launch}"
# Actions array should record both auto-reconciliations.
actions = payload["actions"]
assert any("remove-dev-channel plugin:teams@agent-bridge" in a for a in actions), actions
assert any("remove-dev-channel plugin:cosmax-ep-approval@cosmax-marketplace" in a for a in actions), actions
' "$output"

  # Roster file mirror: the BRIDGE_AGENT_LAUNCH_CMD line on disk must match
  # the audit JSON after_launch — guard against the writer dropping the
  # reconcile delta.
  local after_launch
  after_launch="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"
  smoke_assert_not_contains "$after_launch" "plugin:teams@agent-bridge" \
    "after: roster launch_cmd no longer carries stale teams dev-channel"
  smoke_assert_not_contains "$after_launch" "cosmax-ep-approval" \
    "after: roster launch_cmd no longer carries stale foreign dev-channel"
  smoke_assert_contains "$after_launch" "plugin:ms365@agent-bridge" \
    "after: roster launch_cmd retains ms365 dev-channel"
}

assert_launch_cmd_reconcile_add_new() {
  # Channel-add introduces a new dev-channel; the launch_cmd must gain
  # the matching --dangerously-load-development-channels token in the
  # same audit row (no second pass required).
  write_roster_fixture

  # Start from a state with only ms365.
  run_update --channels-set "plugin:ms365@agent-bridge" >/dev/null

  local output
  output="$(run_update --channels-add "plugin:mattermost")"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
after_launch = payload["after"]["launch_cmd"]
after_channels = payload["after"]["channels"]
assert "plugin:mattermost@agent-bridge" in after_channels, after_channels
assert "plugin:mattermost@agent-bridge" in after_launch, f"new dev-channel not added: {after_launch}"
actions = payload["actions"]
assert any("add-dev-channel plugin:mattermost@agent-bridge" in a for a in actions), actions
' "$output"
}

assert_official_channel_not_added_to_launch() {
  # `plugin:discord@claude-plugins-official` is an OFFICIAL channel —
  # it is loaded by the marketplace at start time, NOT via
  # --dangerously-load-development-channels. The reconciler must not
  # add it to launch_cmd just because the operator added it to
  # BRIDGE_AGENT_CHANNELS. `bridge_filter_development_channels_csv`
  # gates this — verify the gate holds at the update-side.
  write_roster_fixture
  run_update --channels-set "plugin:ms365@agent-bridge" >/dev/null

  local output
  output="$(run_update --channels-add "plugin:discord")"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
after_launch = payload["after"]["launch_cmd"]
after_channels = payload["after"]["channels"]
assert "plugin:discord@claude-plugins-official" in after_channels, after_channels
# Official channel must NOT be loaded via --dangerously-load-development-channels.
assert "plugin:discord@claude-plugins-official" not in after_launch, \
  f"official channel was wrongly injected as dev-channel: {after_launch}"
' "$output"
}

# --- #1236 assertions --------------------------------------------------------

assert_agent_update_help_short_circuits() {
  local out rc=0
  out="$(bash "$SMOKE_REPO_ROOT/bridge-agent.sh" update --help 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    smoke_fail "#1236 agent update --help expected rc=0, got rc=$rc; first line: $(printf '%s' "$out" | head -n1)"
  fi
  smoke_assert_contains "$out" "Usage:" "#1236 agent update --help prints Usage block"
  # The pre-fix path produced "등록된 에이전트:" (treated --help as agent id).
  smoke_assert_not_contains "$out" "등록된 에이전트:" \
    "#1236 agent update --help does NOT fall into registry-list error path"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "γ-cli-consistency"

  smoke_run "#1232 helper restricts to needle on full channel set" \
    assert_target_scoped_helper_only_walks_needle
  smoke_run "#1232 helper matches operator-pinned marketplace" \
    assert_target_scoped_helper_handles_pre_qualified_match

  smoke_run "#1235 agent update --channels alias accepts un-suffixed shorthand" \
    assert_channels_alias_accepted
  smoke_run "#1235 agent update --channels-set normalizes un-suffixed shorthand" \
    assert_channels_set_alias_normalization
  smoke_run "#1235 launch_cmd reconcile removes stale dev-channel tokens" \
    assert_launch_cmd_reconcile_remove_stale
  smoke_run "#1235 launch_cmd reconcile adds new dev-channel tokens" \
    assert_launch_cmd_reconcile_add_new
  smoke_run "#1235 launch_cmd reconcile skips OFFICIAL (non-development) channels" \
    assert_official_channel_not_added_to_launch

  smoke_run "#1236 agent update --help short-circuits to usage" \
    assert_agent_update_help_short_circuits

  smoke_log "passed"
}

main "$@"
