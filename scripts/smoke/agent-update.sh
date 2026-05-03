#!/usr/bin/env bash
# scripts/smoke/agent-update.sh — Issue #528 smoke.
#
# Validates the typed audited update path for protected
# agent-roster.local.sh managed-role fields:
#
# 1. Admin caller from operator-trusted source can add an env-prefix
#    token (--launch-cmd-add-env DEBUG=1).
# 2. Re-running the same add is idempotent (changed=false, sha unchanged).
# 3. --launch-cmd-remove-env reverts the prepend.
# 4. --launch-cmd-add-dev-channel appends the option/spec pair.
# 5. --launch-cmd-remove-dev-channel cleans up option pair + bare token.
# 6. --channels-add / --channels-set / --channels-remove mutate the
#    BRIDGE_AGENT_CHANNELS line.
# 7. --dry-run does not mutate roster on disk; envelope reports the
#    planned change anyway.
# 8. Caller validation: a non-admin caller is denied with a clear reason
#    and the roster is unchanged.
# 9. Audit chain SHA: before_sha and after_sha are both 64-char hex
#    strings. They differ on a real mutation; they match on idempotent /
#    no-op runs.
# 10. Managed-role block delimiters are preserved across rewrites and
#     the rewritten block keeps the agent-create field ordering.
#
# Caller-source trust is forced via BRIDGE_CALLER_SOURCE=operator-tui so
# the smoke does not depend on a real TTY (CI / pipe execution).

set -euo pipefail

SMOKE_NAME="agent-update"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

ADMIN="testadmin"
WORKER="testworker"
NON_ADMIN="testpeer"

write_roster_fixture() {
  # Seed agent-roster.local.sh with two managed-role blocks (one admin,
  # one worker). Use the bash-shell-quoted form `agent-bridge agent
  # create` would emit so the tests exercise the writer's
  # replace_existing path against a realistic input.
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
BRIDGE_AGENT_LAUNCH_CMD["${WORKER}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CHANNELS["${WORKER}"]='plugin:discord@claude-plugins-official'
BRIDGE_AGENT_CONTINUE["${WORKER}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${WORKER}
EOF
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$WORKER" "$BRIDGE_AGENT_HOME_ROOT/$ADMIN"
}

run_update() {
  # Run as admin from operator-trusted source. Override BRIDGE_AGENT_ID
  # so the wrapper sees the strict identity (codex r1 #341 CP5).
  BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_AGENT_ID="$ADMIN" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" update "$WORKER" --json "$@"
}

run_update_as() {
  local caller="$1"
  shift
  BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_AGENT_ID="$caller" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" update "$WORKER" --json "$@"
}

read_field() {
  # Pull the assignment line for the worker agent from the roster
  # file. The test asserts on the literal line emission so any drift
  # in the writer's quoting / ordering trips a clear failure.
  # Indexed by ${WORKER} so the admin block's twin assignment does
  # not shadow the worker line via `head -n 1`.
  local key="$1"
  grep "^${key}\\[\"${WORKER}\"\\]=" "$BRIDGE_ROSTER_LOCAL_FILE" | head -n 1
}

assert_first_add_env_changes_value() {
  local before_line after_line
  before_line="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"

  local output
  output="$(run_update --launch-cmd-add-env DEBUG=1)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["agent"] == "'"$WORKER"'", payload
assert payload["changed"] is True, payload
assert payload["dry_run"] is False, payload
assert "DEBUG=1" in payload["after"]["launch_cmd"], payload
assert "add-env DEBUG=1" in payload["actions"], payload
' "$output"

  after_line="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"
  if [[ "$before_line" == "$after_line" ]]; then
    smoke_fail "expected BRIDGE_AGENT_LAUNCH_CMD line to change after add-env"
  fi
  smoke_assert_contains "$after_line" "DEBUG=1" "roster line carries DEBUG=1 prepend"
}

assert_idempotent_add_env() {
  local before_sha after_sha output
  before_sha="$(sha256sum "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null | awk '{print $1}' || \
                shasum -a 256 "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}')"
  output="$(run_update --launch-cmd-add-env DEBUG=1)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is False, payload
' "$output"
  after_sha="$(sha256sum "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null | awk '{print $1}' || \
               shasum -a 256 "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}')"
  smoke_assert_eq "$before_sha" "$after_sha" "roster sha unchanged on idempotent add-env"
}

assert_remove_env_reverts() {
  local output
  output="$(run_update --launch-cmd-remove-env DEBUG)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
assert "DEBUG=1" not in payload["after"]["launch_cmd"], payload
assert "remove-env DEBUG" in payload["actions"], payload
' "$output"
  local after_line
  after_line="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"
  smoke_assert_not_contains "$after_line" "DEBUG=1" "roster line no longer carries DEBUG=1 after remove"
}

assert_add_dev_channel_appends_pair() {
  local output
  output="$(run_update --launch-cmd-add-dev-channel plugin:foo@m)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
assert "--dangerously-load-development-channels" in payload["after"]["launch_cmd"], payload
assert "plugin:foo@m" in payload["after"]["launch_cmd"], payload
assert "add-dev-channel plugin:foo@m" in payload["actions"], payload
' "$output"
  local after_line
  after_line="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"
  smoke_assert_contains "$after_line" "plugin:foo@m" "roster argv carries dev-channel spec"
}

assert_remove_dev_channel_cleans_pair() {
  local output
  output="$(run_update --launch-cmd-remove-dev-channel plugin:foo@m)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
assert "plugin:foo@m" not in payload["after"]["launch_cmd"], payload
assert "remove-dev-channel plugin:foo@m" in payload["actions"], payload
' "$output"
  local after_line
  after_line="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"
  smoke_assert_not_contains "$after_line" "plugin:foo@m" "roster argv no longer carries dev-channel spec"
}

assert_set_launch_cmd_full_replace() {
  # Codex r1 finding 5: --set-launch-cmd (full replace) was the only
  # mutation flag the smoke did not exercise. Cover round-trip on the
  # JSON envelope, the on-disk roster line, and the post-replace
  # idempotency. The prior dev-channel test pair restored worker's
  # launch_cmd to `claude --dangerously-skip-permissions`, so the new
  # value asserted here is structurally distinct from the fixture.
  local before_line after_line output
  before_line="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"
  output="$(run_update --set-launch-cmd "claude --dangerously-skip-permissions --resume")"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
assert payload["after"]["launch_cmd"] == "claude --dangerously-skip-permissions --resume", payload
assert "set-launch-cmd" in payload["actions"], payload
' "$output"
  after_line="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"
  if [[ "$before_line" == "$after_line" ]]; then
    smoke_fail "expected BRIDGE_AGENT_LAUNCH_CMD line to change after set-launch-cmd"
  fi
  smoke_assert_contains "$after_line" "claude --dangerously-skip-permissions --resume" \
    "roster line carries replaced launch_cmd"

  # Idempotent re-run reports changed=false.
  output="$(run_update --set-launch-cmd "claude --dangerously-skip-permissions --resume")"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is False, payload
' "$output"

  # Restore the fixture so downstream assertions see the original value.
  run_update --set-launch-cmd "claude --dangerously-skip-permissions" >/dev/null
}

assert_channels_family() {
  # Add unique token, set full replace, remove one token. Each step
  # confirms the JSON envelope and the on-disk channels line move.
  local output line
  output="$(run_update --channels-add plugin:teams@agent-bridge)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
assert "plugin:teams@agent-bridge" in payload["after"]["channels"], payload
' "$output"
  line="$(read_field "BRIDGE_AGENT_CHANNELS")"
  smoke_assert_contains "$line" "plugin:teams@agent-bridge" "channels line carries added token"

  output="$(run_update --channels-set plugin:discord@claude-plugins-official,plugin:mattermost@claude-plugins-official)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
assert payload["after"]["channels"] == "plugin:discord@claude-plugins-official,plugin:mattermost@claude-plugins-official", payload
' "$output"
  line="$(read_field "BRIDGE_AGENT_CHANNELS")"
  smoke_assert_contains "$line" "plugin:mattermost@claude-plugins-official" "channels-set replaced csv on disk"
  smoke_assert_not_contains "$line" "plugin:teams@agent-bridge" "channels-set removed previously-added token"

  output="$(run_update --channels-remove plugin:mattermost@claude-plugins-official)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
assert "plugin:mattermost@claude-plugins-official" not in payload["after"]["channels"], payload
' "$output"
  line="$(read_field "BRIDGE_AGENT_CHANNELS")"
  smoke_assert_not_contains "$line" "plugin:mattermost@claude-plugins-official" "channels-remove dropped token"
}

assert_dry_run_does_not_mutate() {
  local before_sha after_sha output
  before_sha="$(sha256sum "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null | awk '{print $1}' || \
                shasum -a 256 "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}')"
  output="$(run_update --launch-cmd-add-env TRACE=1 --dry-run)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["dry_run"] is True, payload
assert payload["changed"] is True, payload
assert "TRACE=1" in payload["after"]["launch_cmd"], payload
' "$output"
  after_sha="$(sha256sum "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null | awk '{print $1}' || \
               shasum -a 256 "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}')"
  smoke_assert_eq "$before_sha" "$after_sha" "dry-run leaves roster sha unchanged"

  local line
  line="$(read_field "BRIDGE_AGENT_LAUNCH_CMD")"
  smoke_assert_not_contains "$line" "TRACE=1" "dry-run did not write planned env to disk"
}

assert_caller_validation_denies_non_admin() {
  local before_sha after_sha rc=0 output
  before_sha="$(sha256sum "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null | awk '{print $1}' || \
                shasum -a 256 "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}')"
  set +e
  output="$(run_update_as "$NON_ADMIN" --launch-cmd-add-env BAD=1 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "expected non-admin caller to be rejected, exit=0; output=$output"
  fi
  smoke_assert_contains "$output" "is not the admin agent" "deny reason mentions admin gate"
  after_sha="$(sha256sum "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null | awk '{print $1}' || \
               shasum -a 256 "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}')"
  smoke_assert_eq "$before_sha" "$after_sha" "denied call leaves roster sha unchanged"
}

assert_audit_sha_chain() {
  # Run a real mutation; capture before_sha + after_sha from JSON.
  local output before_sha after_sha
  output="$(run_update --launch-cmd-add-env CHAIN=1)"
  before_sha="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["before_sha"])')"
  after_sha="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["after_sha"])')"

  if [[ ! "$before_sha" =~ ^[0-9a-f]{64}$ ]]; then
    smoke_fail "before_sha is not a 64-char hex sha256: '$before_sha'"
  fi
  if [[ ! "$after_sha" =~ ^[0-9a-f]{64}$ ]]; then
    smoke_fail "after_sha is not a 64-char hex sha256: '$after_sha'"
  fi
  if [[ "$before_sha" == "$after_sha" ]]; then
    smoke_fail "sha chain did not advance after a real mutation"
  fi

  # Idempotent re-run: sha must match.
  output="$(run_update --launch-cmd-add-env CHAIN=1)"
  before_sha="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["before_sha"])')"
  after_sha="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["after_sha"])')"
  smoke_assert_eq "$before_sha" "$after_sha" "idempotent re-run leaves sha chain unchanged"

  # Cleanup so other assertions start from a known state.
  run_update --launch-cmd-remove-env CHAIN >/dev/null
}

assert_managed_block_preserved() {
  # The rewritten roster must still carry the BEGIN/END delimiters and
  # the bridge_add_agent_id_if_missing line that bridge_write_role_block
  # always emits first inside the managed block. This pins the contract
  # that the typed updater reuses the writer rather than reinventing
  # shell edits.
  local content
  content="$(cat "$BRIDGE_ROSTER_LOCAL_FILE")"
  smoke_assert_contains "$content" "# BEGIN AGENT BRIDGE MANAGED ROLE: ${WORKER}" "begin marker preserved"
  smoke_assert_contains "$content" "# END AGENT BRIDGE MANAGED ROLE: ${WORKER}" "end marker preserved"
  smoke_assert_contains "$content" "bridge_add_agent_id_if_missing ${WORKER}" "writer-emitted helper line preserved"

  # Field order inside the block: DESC must precede LAUNCH_CMD.
  python3 - "$BRIDGE_ROSTER_LOCAL_FILE" "$WORKER" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
worker = sys.argv[2]
pattern = re.compile(
    rf"# BEGIN AGENT BRIDGE MANAGED ROLE: {re.escape(worker)}\n(.*?)\n# END AGENT BRIDGE MANAGED ROLE: {re.escape(worker)}",
    re.DOTALL,
)
m = pattern.search(text)
assert m, "managed block not found"
body = m.group(1)
desc_idx = body.index("BRIDGE_AGENT_DESC")
launch_idx = body.index("BRIDGE_AGENT_LAUNCH_CMD")
assert desc_idx < launch_idx, f"DESC must come before LAUNCH_CMD: desc={desc_idx} launch={launch_idx}"
PY
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd bash
  smoke_setup_bridge_home "agent-update"
  write_roster_fixture
  smoke_run "first add-env mutates launch_cmd"           assert_first_add_env_changes_value
  smoke_run "second add-env is idempotent"               assert_idempotent_add_env
  smoke_run "remove-env reverts the prepend"             assert_remove_env_reverts
  smoke_run "add-dev-channel appends option/spec pair"   assert_add_dev_channel_appends_pair
  smoke_run "remove-dev-channel cleans up pair + token"  assert_remove_dev_channel_cleans_pair
  smoke_run "set-launch-cmd full replace + idempotent"   assert_set_launch_cmd_full_replace
  smoke_run "channels add/set/remove family round-trip"  assert_channels_family
  smoke_run "dry-run does not mutate roster"             assert_dry_run_does_not_mutate
  smoke_run "non-admin caller is denied with reason"     assert_caller_validation_denies_non_admin
  smoke_run "audit chain SHA advances + idempotent stays" assert_audit_sha_chain
  smoke_run "managed-role block delimiters/order preserved" assert_managed_block_preserved
  smoke_log "passed"
}

main "$@"
