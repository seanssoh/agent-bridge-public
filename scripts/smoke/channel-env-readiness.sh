#!/usr/bin/env bash

# Issue #534: lock the contract for the isolation-aware channel `.env`
# readiness probe. The probe must:
#
# 1. Return "present" when at least one requested key has a non-empty value.
# 2. Return "missing" when the file exists but no requested key is present
#    with a non-empty value.
# 3. Return "missing" when the file is absent.
# 4. Return "present" after a successful linux-user ACL repair retry.
# 5. Return "unreadable" after bounded ACL repair attempts fail.
# 6. Suppress raw grep stderr in all cases (issue body's primary symptom).
# 7. Have status_reason emit a distinct "unreadable: ..." line with an
#    ACL diagnostic blob (instead of the false-negative "missing token").
# 8. Cover the ms365 channel branch in status_reason (was previously absent).
#
# The smoke is Linux-only by design — POSIX named-user ACLs and getfacl
# behave differently on Darwin, so the unreadable-with-repair scenarios
# cannot be reproduced faithfully on macOS. macOS auto-skips with exit 0
# so the orchestrator's local runs do not regress; CI on Linux must
# exercise the assertions.

set -euo pipefail

SMOKE_NAME="channel-env-readiness"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

case "$(uname -s 2>/dev/null || printf '')" in
  Linux) ;;
  *)
    smoke_log "skipping on non-Linux host (POSIX ACL primitives unavailable)"
    exit 0
    ;;
esac

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

source_bridge_lib() {
  # shellcheck source=bridge-lib.sh
  source "$SMOKE_REPO_ROOT/bridge-lib.sh"
  bridge_load_roster
}

WORKER="worker534"
WORKDIR=""
TEAMS_DIR=""
TEAMS_ENV=""
MS365_DIR=""
MS365_ENV=""

# Mock state for ACL repair injection. The call counter lives in a file
# because bridge_channel_env_file_readiness is invoked through `$(...)`,
# which forks a subshell — in-memory counters in the parent would not
# observe increments from the override running inside that subshell.
MOCK_REPAIR_BEHAVIOR="none"   # none | restore | nop
MOCK_REPAIR_COUNT_FILE=""

register_worker() {
  WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$WORKER"
  TEAMS_DIR="$WORKDIR/.teams"
  TEAMS_ENV="$TEAMS_DIR/.env"
  MS365_DIR="$WORKDIR/.ms365"
  MS365_ENV="$MS365_DIR/.env"
  MOCK_REPAIR_COUNT_FILE="$SMOKE_TMP_ROOT/repair.count"
  echo 0 >"$MOCK_REPAIR_COUNT_FILE"
  export TEAMS_ENV MS365_ENV MOCK_REPAIR_COUNT_FILE MOCK_REPAIR_BEHAVIOR
  mkdir -p "$WORKDIR" "$TEAMS_DIR" "$MS365_DIR"
  bridge_add_agent_id_if_missing "$WORKER"
  BRIDGE_AGENT_ENGINE["$WORKER"]="claude"
  BRIDGE_AGENT_SOURCE["$WORKER"]="static"
  BRIDGE_AGENT_SESSION["$WORKER"]="$WORKER-session"
  BRIDGE_AGENT_WORKDIR["$WORKER"]="$WORKDIR"
  BRIDGE_AGENT_LOOP["$WORKER"]=0
  BRIDGE_AGENT_CONTINUE["$WORKER"]=0
  BRIDGE_AGENT_ISOLATION_MODE["$WORKER"]="linux-user"
  BRIDGE_AGENT_OS_USER["$WORKER"]="$(id -un)"
  BRIDGE_AGENT_CHANNELS["$WORKER"]="plugin:teams,plugin:ms365"
}

write_present_teams_env() {
  cat >"$TEAMS_ENV" <<EOF
TEAMS_APP_ID=appid-value
TEAMS_APP_PASSWORD=apppass-value
EOF
}

write_empty_teams_env() {
  cat >"$TEAMS_ENV" <<'EOF'
TEAMS_APP_ID=
TEAMS_APP_PASSWORD=
EOF
}

write_present_ms365_env() {
  cat >"$MS365_ENV" <<EOF
MS365_CLIENT_ID=client-id
MS365_CLIENT_SECRET=client-secret
MS365_TENANT_ID=tenant-id
EOF
}

# Install our mock AFTER bridge-lib.sh has been sourced, otherwise the
# real definition from lib/bridge-agents.sh would clobber the override.
# The fixture uses chmod 000 to simulate "controller cannot read" without
# requiring sudo / setfacl; mock behaviors:
#   - none:    do nothing (file stays unreadable).
#   - restore: chmod 600 the file so a subsequent [[ -r ]] succeeds.
#   - nop:     count attempts but do nothing.
install_repair_mock() {
  bridge_linux_acl_repair_channel_env_files() {
    local agent="$1"
    local n
    n=$(($(cat "$MOCK_REPAIR_COUNT_FILE" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$MOCK_REPAIR_COUNT_FILE"
    case "$MOCK_REPAIR_BEHAVIOR" in
      restore)
        [[ -e "$TEAMS_ENV" ]] && chmod 600 "$TEAMS_ENV" 2>/dev/null || true
        [[ -e "$MS365_ENV" ]] && chmod 600 "$MS365_ENV" 2>/dev/null || true
        ;;
      nop|none|*)
        :
        ;;
    esac
    : "${agent}"
  }
}

reset_repair_mock() {
  MOCK_REPAIR_BEHAVIOR="$1"
  export MOCK_REPAIR_BEHAVIOR
  echo 0 >"$MOCK_REPAIR_COUNT_FILE"
}

repair_calls() {
  cat "$MOCK_REPAIR_COUNT_FILE" 2>/dev/null || echo 0
}

# Capture stderr of a helper invocation into a file. Returns stdout to
# caller and writes stderr to $1.
capture_stderr_file() {
  local stderr_path="$1"; shift
  "$@" 2>"$stderr_path"
}

assert_present_with_value() {
  write_present_teams_env
  reset_repair_mock none
  local out
  out="$(bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID MicrosoftAppId)"
  smoke_assert_eq "present" "$out" "readable .env with non-empty key returns present"
}

assert_missing_with_empty_value() {
  write_empty_teams_env
  reset_repair_mock none
  local out
  out="$(bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID MicrosoftAppId)"
  smoke_assert_eq "missing" "$out" "readable .env with empty values returns missing"
}

assert_missing_when_file_absent() {
  rm -f "$TEAMS_ENV"
  reset_repair_mock none
  local out
  out="$(bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID MicrosoftAppId)"
  smoke_assert_eq "missing" "$out" "absent .env returns missing"
}

assert_unreadable_then_repaired() {
  write_present_teams_env
  chmod 000 "$TEAMS_ENV"
  reset_repair_mock restore
  local out calls
  out="$(bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID MicrosoftAppId)"
  smoke_assert_eq "present" "$out" "unreadable .env recovers to present after ACL repair restores readability"
  calls="$(repair_calls)"
  if (( calls < 1 )); then
    smoke_fail "expected ACL repair to be invoked at least once; got $calls"
  fi
  chmod 600 "$TEAMS_ENV" 2>/dev/null || true
}

assert_unreadable_when_repair_fails() {
  write_present_teams_env
  chmod 000 "$TEAMS_ENV"
  reset_repair_mock nop
  local out calls
  out="$(bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID MicrosoftAppId)"
  smoke_assert_eq "unreadable" "$out" "unreadable .env stays unreadable after bounded repair attempts fail"
  calls="$(repair_calls)"
  if (( calls < 2 )); then
    smoke_fail "expected at least 2 repair attempts (BRIDGE_ENV_READINESS_REPAIR_ATTEMPTS default); got $calls"
  fi
  chmod 600 "$TEAMS_ENV" 2>/dev/null || true
}

assert_no_grep_stderr_leakage() {
  local stderr_path="$SMOKE_TMP_ROOT/readiness-stderr.log"
  : >"$stderr_path"

  # Scenario 1: present
  write_present_teams_env
  reset_repair_mock none
  capture_stderr_file "$stderr_path" bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID >/dev/null
  if [[ -s "$stderr_path" ]]; then
    smoke_fail "no-stderr scenario 1 (present) leaked: $(cat "$stderr_path")"
  fi

  # Scenario 2: missing key
  write_empty_teams_env
  capture_stderr_file "$stderr_path" bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID >/dev/null
  if [[ -s "$stderr_path" ]]; then
    smoke_fail "no-stderr scenario 2 (missing key) leaked: $(cat "$stderr_path")"
  fi

  # Scenario 3: file absent
  rm -f "$TEAMS_ENV"
  capture_stderr_file "$stderr_path" bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID >/dev/null
  if [[ -s "$stderr_path" ]]; then
    smoke_fail "no-stderr scenario 3 (absent) leaked: $(cat "$stderr_path")"
  fi

  # Scenario 4: unreadable then repaired
  write_present_teams_env
  chmod 000 "$TEAMS_ENV"
  reset_repair_mock restore
  capture_stderr_file "$stderr_path" bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID >/dev/null
  if [[ -s "$stderr_path" ]]; then
    smoke_fail "no-stderr scenario 4 (unreadable->repaired) leaked: $(cat "$stderr_path")"
  fi
  chmod 600 "$TEAMS_ENV" 2>/dev/null || true

  # Scenario 5: unreadable repair fails
  chmod 000 "$TEAMS_ENV"
  reset_repair_mock nop
  capture_stderr_file "$stderr_path" bridge_channel_env_file_readiness "$WORKER" "plugin:teams" "$TEAMS_ENV" TEAMS_APP_ID >/dev/null
  if [[ -s "$stderr_path" ]]; then
    smoke_fail "no-stderr scenario 5 (unreadable->fail) leaked: $(cat "$stderr_path")"
  fi
  chmod 600 "$TEAMS_ENV" 2>/dev/null || true
}

assert_status_reason_unreadable_with_diagnostic() {
  # Set up: teams .env unreadable with mock repair that does nothing, so
  # status_reason should emit the new "unreadable: ..." form with the
  # ACL diagnostic blob.
  mkdir -p "$TEAMS_DIR"
  : >"$TEAMS_DIR/access.json"
  write_present_teams_env
  chmod 000 "$TEAMS_ENV"
  reset_repair_mock nop

  # Restrict required runtime channels to teams only for this assertion.
  local saved_channels="${BRIDGE_AGENT_CHANNELS[$WORKER]-}"
  BRIDGE_AGENT_CHANNELS["$WORKER"]="plugin:teams"

  local reason
  reason="$(bridge_agent_runtime_channel_status_reason "$WORKER")"

  smoke_assert_contains "$reason" "unreadable: Teams .env" \
    "status_reason emits unreadable prefix for Teams when .env is unreadable"
  smoke_assert_contains "$reason" "ACL repair failed" \
    "status_reason includes ACL repair attempt count phrase"
  smoke_assert_contains "$reason" '"mode":' \
    "status_reason embeds ACL diagnostic blob (mode field)"

  # Single line — no embedded newlines — log-parser safe.
  local newlines
  newlines="$(printf '%s' "$reason" | tr -cd '\n' | wc -c | tr -d ' ')"
  smoke_assert_eq "0" "$newlines" "status_reason for unreadable case stays single-line"

  BRIDGE_AGENT_CHANNELS["$WORKER"]="$saved_channels"
  chmod 600 "$TEAMS_ENV" 2>/dev/null || true
}

assert_ms365_branch_covered() {
  # Set up: only ms365 required, .env present with valid keys. The new
  # ms365 branch must process this without requiring access.json. Unlike
  # Teams/Discord/Mattermost, ms365 is token/env based and has no allowlist
  # access file in its runtime contract.
  mkdir -p "$MS365_DIR"
  rm -f "$MS365_DIR/access.json"
  write_present_ms365_env
  reset_repair_mock none

  local saved_channels="${BRIDGE_AGENT_CHANNELS[$WORKER]-}"
  BRIDGE_AGENT_CHANNELS["$WORKER"]="plugin:ms365"

  local reason
  reason="$(bridge_agent_runtime_channel_status_reason "$WORKER")"
  smoke_assert_eq "" "$reason" "ms365 with all keys present and no access.json produces empty status_reason (ok)"
  smoke_assert_eq "n/a" "$(bridge_channel_access_status_for_item "$WORKER" "plugin:ms365")" \
    "ms365 reports access_status n/a because it has no access.json contract"

  # Now break the ms365 .env — the branch must surface that, proving it
  # is not silently falling through after the access.json check was removed.
  : >"$MS365_ENV"
  reason="$(bridge_agent_runtime_channel_status_reason "$WORKER")"
  smoke_assert_contains "$reason" "missing MS365 client id" \
    "ms365 branch surfaces missing .env keys (proves branch is reached)"

  # Restore for unreadable-detection sub-check.
  write_present_ms365_env
  chmod 000 "$MS365_ENV"
  reset_repair_mock nop
  reason="$(bridge_agent_runtime_channel_status_reason "$WORKER")"
  smoke_assert_contains "$reason" "unreadable: MS365 .env" \
    "ms365 branch emits unreadable prefix when .env is unreadable"

  chmod 600 "$MS365_ENV" 2>/dev/null || true
  BRIDGE_AGENT_CHANNELS["$WORKER"]="$saved_channels"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "channel-env-readiness"
  source_bridge_lib
  register_worker
  install_repair_mock

  smoke_run "readable .env with non-empty key returns present"           assert_present_with_value
  smoke_run "readable .env with empty values returns missing"            assert_missing_with_empty_value
  smoke_run "absent .env returns missing"                                assert_missing_when_file_absent
  smoke_run "unreadable .env recovers via ACL repair retry"              assert_unreadable_then_repaired
  smoke_run "unreadable .env stays unreadable when repair fails"         assert_unreadable_when_repair_fails
  smoke_run "no raw grep stderr leakage in any readiness scenario"       assert_no_grep_stderr_leakage
  smoke_run "status_reason emits unreadable + ACL diagnostic"            assert_status_reason_unreadable_with_diagnostic
  smoke_run "ms365 status_reason branch covers all three states"         assert_ms365_branch_covered
  smoke_log "passed"
}

main "$@"
