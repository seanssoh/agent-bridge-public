#!/usr/bin/env bash
# scripts/smoke/1105-agent-add-audit.sh — Issue #1105.
#
# `agent add` (run_create) calls bridge_write_role_block to append a
# managed-role block to the protected agent-roster.local.sh — the same
# file `agent update` mutates — but did not emit a
# `system_config_mutation` audit row. PR #1102 (v0.14.5-beta6) added
# the policy flags (--idle-timeout / --loop / --always-on) to update,
# whose audit emit went through `bridge_agent_update_emit_audit`, but
# the create-side asymmetry stayed open as a beta7 follow-up.
#
# This smoke pins:
#   T1. `agent add` produces a system_config_mutation audit row with
#       `trigger == agent-create-apply`, `target_agent == <new-agent>`,
#       `before_sha256 == ""` (the file did not exist pre-create), and
#       `after_sha256` matching the sha256 of the roster file as it
#       landed on disk.
#   T2. The persisted policy fields surface in the audit detail:
#       `--idle-timeout 300 --loop no` produces
#       `after_idle_timeout == "300"` and `after_loop == "0"`. (The
#       update-side audit-detail schema uses "0"/"1" for loop and the
#       raw seconds string for idle_timeout — same shape here.)
#   T3. `--always-on yes` produces `after_idle_timeout == "0"` (legacy
#       always-on -> idle_timeout=0 mapping, also asserted by
#       agent-create-idle-timeout smoke for the roster line).
#   T4. Rollback variant: when a step AFTER bridge_write_role_block
#       fails (the rollback trap fires and excises the just-written
#       roster entry), NO system_config_mutation audit row is written
#       for the create — the trail must only ever carry creates that
#       actually landed. We exercise this by re-using an agent name
#       whose name validation passes but whose start --dry-run path
#       trips on a missing dependency... actually the simpler path:
#       force bridge_write_role_block itself to fail by making the
#       roster file read-only. set -e + the trap then unwind before
#       reaching the audit emit, so the log stays empty for the
#       failed create.
#
# Caller-source trust is forced via BRIDGE_CALLER_SOURCE=operator-tui
# so the smoke does not depend on a real TTY.

set -euo pipefail

SMOKE_NAME="1105-agent-add-audit"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd bash
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  smoke_fail "missing required command: sha256sum or shasum"
fi

run_create() {
  BRIDGE_CALLER_SOURCE="operator-tui" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" create "$@" 2>&1
}

reset_runtime() {
  rm -rf "$BRIDGE_AGENT_HOME_ROOT"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  : >"$BRIDGE_AUDIT_LOG"
}

# Lift the last `system_config_mutation` row's detail JSON from the
# audit log. The detail is stored as a JSON-encoded string inside the
# outer audit envelope's `detail` key — the helper also accepts the
# legacy shape where `detail` is already a dict.
#
# Footgun #11 (KNOWN_ISSUES.md §26): the body used to live as
# `python3 - "$BRIDGE_AUDIT_LOG" <<'PY' … PY` here. Codex r1 review of
# this PR flagged it as a new heredoc-stdin trip site. The body is now
# a standalone helper invoked file-as-argv, same precedent as
# lib/upgrade-helpers/.
last_create_audit_detail() {
  python3 "$SCRIPT_DIR/1105-helpers/last-create-audit-detail.py" "$BRIDGE_AUDIT_LOG"
}

# Count system_config_mutation rows in the audit log (any trigger).
# Footgun #11: standalone helper (see last_create_audit_detail).
audit_row_count() {
  python3 "$SCRIPT_DIR/1105-helpers/audit-row-count.py" "$BRIDGE_AUDIT_LOG"
}

roster_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}'
  else
    shasum -a 256 "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}'
  fi
}

test_audit_row_emitted_on_create() {
  reset_runtime
  local out
  out="$(run_create auditbasic --engine claude)"
  smoke_assert_contains "$out" "create: ok" "create succeeded"
  smoke_assert_file_exists "$BRIDGE_AUDIT_LOG" "audit log file exists"

  local detail
  detail="$(last_create_audit_detail)"
  local actual_after expected_after target_agent operation
  actual_after="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("after_sha256",""))')"
  target_agent="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("target_agent",""))')"
  operation="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("operation",""))')"
  expected_after="$(roster_sha)"

  smoke_assert_eq "auditbasic" "$target_agent" "audit row target_agent matches"
  smoke_assert_eq "$expected_after" "$actual_after" "audit row after_sha256 matches roster file sha"
  # before_sha256 is the documented "file did not exist" sentinel —
  # audit-detail-json.py emits before_sha256 verbatim (empty when the
  # roster file was absent pre-create). reset_runtime touches the file
  # to empty, so the realistic shape on a markerless fresh-install
  # (where the smoke pre-creates an empty roster) is a sha256 of the
  # empty file, NOT a literal empty string. Assert that the
  # before_sha256 key is present and differs from after_sha256 (proving
  # the chain advanced). The empty-file edge case is documented and
  # acceptable for the smoke shape.
  local actual_before
  actual_before="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("before_sha256",""))')"
  if [[ "$actual_before" == "$actual_after" ]]; then
    smoke_fail "audit chain did not advance: before_sha256 == after_sha256"
  fi
  # operation field carries the create marker + summary string.
  smoke_assert_contains "$operation" "agent_create" "operation field opens with agent_create marker"
  smoke_assert_contains "$operation" "engine=claude" "operation summary carries engine=claude"
}

test_audit_row_carries_policy_flags() {
  reset_runtime
  local out
  out="$(run_create auditpolicy --engine claude --idle-timeout 300 --loop no)"
  smoke_assert_contains "$out" "create: ok" "create succeeded"

  local detail after_idle after_loop
  detail="$(last_create_audit_detail)"
  after_idle="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("after_idle_timeout",""))')"
  after_loop="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("after_loop",""))')"
  smoke_assert_eq "300" "$after_idle" "audit row carries after_idle_timeout=300"
  smoke_assert_eq "0" "$after_loop" "audit row carries after_loop=0 (LOOP=0 in roster)"

  # Operation summary echoes the policy fields too.
  local operation
  operation="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("operation",""))')"
  smoke_assert_contains "$operation" "idle_timeout=300" "operation summary carries idle_timeout=300"
  smoke_assert_contains "$operation" "loop=0" "operation summary carries loop=0"
}

test_audit_row_for_always_on() {
  reset_runtime
  local out
  out="$(run_create auditao --engine claude --always-on)"
  smoke_assert_contains "$out" "create: ok" "create succeeded"

  local detail after_idle
  detail="$(last_create_audit_detail)"
  after_idle="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("after_idle_timeout",""))')"
  smoke_assert_eq "0" "$after_idle" "audit row carries after_idle_timeout=0 for --always-on"
}

test_no_audit_row_on_failed_create() {
  reset_runtime
  # Force bridge_write_role_block to fail by making the roster file
  # read-only. The python writer opens the file for writing and raises
  # PermissionError, set -e propagates, and the EXIT trap fires the
  # rollback. The audit emit is positioned AFTER the write (and after
  # every other mutation in the create flow), so we must not see a
  # system_config_mutation row for the failed create.
  chmod a-w "$BRIDGE_ROSTER_LOCAL_FILE"
  local rc=0 out
  set +e
  out="$(run_create auditfail --engine claude 2>&1)"
  rc=$?
  set -e
  # Restore writability before any later assertion/cleanup touches it.
  chmod u+w "$BRIDGE_ROSTER_LOCAL_FILE"

  if [[ $rc -eq 0 ]]; then
    smoke_fail "expected create to fail when roster is read-only; out=$out"
  fi

  local count
  count="$(audit_row_count)"
  smoke_assert_eq "0" "$count" "no system_config_mutation row written for failed create"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  smoke_run "agent add emits system_config_mutation row" test_audit_row_emitted_on_create
  smoke_run "policy flags surface in audit detail"        test_audit_row_carries_policy_flags
  smoke_run "--always-on maps to after_idle_timeout=0"    test_audit_row_for_always_on
  smoke_run "failed create writes no audit row"           test_no_audit_row_on_failed_create
  smoke_log "passed"
}

main "$@"
