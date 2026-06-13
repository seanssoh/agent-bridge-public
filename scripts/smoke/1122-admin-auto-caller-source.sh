#!/usr/bin/env bash
# scripts/smoke/1122-admin-auto-caller-source.sh — Issue #1122 smoke.
#
# Inside an admin Claude Code session every protected `agent` subcommand
# (`create`, `update`, `delete`) requires
# `BRIDGE_CALLER_SOURCE=operator-trusted-id` because the Claude Code Bash
# tool runs each command in a non-interactive subshell that the
# TTY-detected `operator-tui` branch never matches. This smoke locks in
# the auto-promotion gate from #1122:
#
#   - When `BRIDGE_AGENT_ID == BRIDGE_ADMIN_AGENT_ID` (both non-empty)
#     AND `BRIDGE_CALLER_SOURCE` is unset, the source is implicitly
#     promoted to `operator-trusted-id` and the mutation is allowed.
#   - A `caller_source_auto_promotion` audit row is written so the
#     promotion is diagnoseable post-hoc.
#   - A non-admin session with no explicit override is STILL rejected
#     (the security boundary did not move).
#   - An anonymous session (no BRIDGE_AGENT_ID or no admin configured)
#     is STILL rejected.
#   - A NON-admin agent session that FORGES a trusted `BRIDGE_CALLER_SOURCE`
#     (operator-tui / operator-trusted-id) is STILL rejected. Issue #1879
#     PR #1887 r3 moved agent-session trust onto the non-forgeable admin
#     IDENTITY: an agent process carries BRIDGE_AGENT_ID into any
#     subshell / `bash -c` / `eval`, so a non-admin's inherited
#     BRIDGE_CALLER_SOURCE claim is ignored and the session stays
#     agent-direct. The admin agent is promoted by its identity regardless
#     of any stray inherited BRIDGE_CALLER_SOURCE (it has no need to forge
#     a source — its admin identity IS the trust).
#
# Roster contract: `bridge_reset_roster_maps` (lib/bridge-core.sh) unsets
# BRIDGE_ADMIN_AGENT_ID before reloading the roster, so the smoke must
# either (a) write `BRIDGE_ADMIN_AGENT_ID=<admin>` into the roster file
# itself (mirroring the pattern in scripts/smoke/agent-doctor.sh) or
# (b) accept that an env-only admin id will be stripped before the gate.
# We use (a) so each case exercises the same code path the operator hits
# in production.
#
# Assertions are exercised through `bridge-agent.sh create --dry-run`,
# the same surface the operator hit in the reproduction (issue #1122).

set -euo pipefail

SMOKE_NAME="1122-admin-auto-caller-source"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

ADMIN="patch"

# Bash 4+ is required by lib/bridge-agent-update.sh (parameter expansion
# `${var,,}`). Fall back to Homebrew bash on macOS where /usr/bin/env
# bash resolves to /bin/bash 3.2. Mirrors the resolver in
# scripts/smoke/agent-doctor.sh.
BASH4_BIN="${BASH:-bash}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

write_admin_roster() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID=$ADMIN
EOF
}

# Roster file with no admin id — exercises the "anonymous / unconfigured"
# cases below. Mirrors a fresh BRIDGE_HOME before `agent-bridge setup
# admin` has run.
write_empty_roster() {
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
}

# run_create — invoke `agent create` with the per-case env overrides.
# Every invocation runs inside `$(...)`, so stdin/stdout are not TTYs
# and the TTY branch of bridge_agent_update_caller_source cannot fire.
run_create() {
  "$BASH4_BIN" "$SMOKE_REPO_ROOT/bridge-agent.sh" create "$@" 2>&1 || true
}

reset_runtime() {
  rm -rf "$BRIDGE_AGENT_HOME_ROOT"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT"
  # Truncate audit log between cases so the auto-promotion assertion
  # only sees rows produced by the current call.
  : >"$BRIDGE_AUDIT_LOG"
  # Clear any prior auto-promotion flag a previous case may have
  # exported into our process. Each case must enter clean so the
  # once-per-process gate behaves the same way it does for a fresh
  # `agent-bridge` invocation in production.
  unset BRIDGE_AGENT_CALLER_SOURCE_AUTO_PROMOTED
}

assert_admin_session_auto_promoted() {
  reset_runtime
  write_admin_roster
  local out
  # Admin session: BRIDGE_AGENT_ID matches BRIDGE_ADMIN_AGENT_ID (both
  # via roster + via the env handoff the bridge-managed admin shell sees
  # at launch). No explicit BRIDGE_CALLER_SOURCE → must auto-promote to
  # operator-trusted-id and the create plan must reach the dry-run path.
  out="$(BRIDGE_AGENT_ID="$ADMIN" BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
    run_create dev_test --engine claude --dry-run)"
  smoke_assert_not_contains "$out" "not allowed to mutate system config" \
    "T1: admin-session create passes the caller-trust gate without explicit BRIDGE_CALLER_SOURCE"
  smoke_assert_contains "$out" "agent: dev_test" \
    "T1: admin-session create reaches the create plan path"
  smoke_assert_contains "$out" "dry_run: yes" \
    "T1: admin-session create completes the dry-run plan"

  # Audit log must contain the auto-promotion event with the expected
  # detail shape. We check for the action label first (uniquely names
  # the row) and then the structured detail fields.
  smoke_assert_file_exists "$BRIDGE_AUDIT_LOG" \
    "T1: audit log file exists after admin auto-promoted create"
  local audit_contents
  audit_contents="$(cat "$BRIDGE_AUDIT_LOG")"
  smoke_assert_contains "$audit_contents" '"action": "caller_source_auto_promotion"' \
    "T1: audit log carries the caller_source_auto_promotion row"
  smoke_assert_contains "$audit_contents" '"caller_source_auto": true' \
    "T1: audit detail records caller_source_auto: true"
  smoke_assert_contains "$audit_contents" '"derived_from": "admin-agent-signal"' \
    "T1: audit detail records derived_from: admin-agent-signal"
  smoke_assert_contains "$audit_contents" '"promoted_to": "operator-trusted-id"' \
    "T1: audit detail records promoted_to: operator-trusted-id"
}

assert_non_admin_session_denied() {
  reset_runtime
  write_admin_roster
  local out
  # Non-admin session: BRIDGE_AGENT_ID is set but does NOT match
  # BRIDGE_ADMIN_AGENT_ID. No explicit BRIDGE_CALLER_SOURCE → must
  # NOT auto-promote, must fall through to agent-direct, must be
  # rejected. The security boundary is what this case locks in.
  out="$(BRIDGE_AGENT_ID="worker_a" BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
    run_create dev_test --engine claude --dry-run)"
  smoke_assert_contains "$out" "deny:" \
    "T2: non-admin session is denied"
  smoke_assert_contains "$out" "caller source agent-direct is not allowed to mutate system config" \
    "T2: deny reason names the agent-direct caller source"
  # And the auto-promotion audit row must NOT be present — a non-admin
  # session never trips the promotion path.
  local audit_contents
  audit_contents="$(cat "$BRIDGE_AUDIT_LOG" 2>/dev/null || printf '')"
  smoke_assert_not_contains "$audit_contents" '"action": "caller_source_auto_promotion"' \
    "T2: non-admin session does NOT emit the auto-promotion audit row"
}

assert_anonymous_session_denied() {
  reset_runtime
  write_admin_roster
  local out
  # Anonymous session: BRIDGE_AGENT_ID unset entirely. No agent-id to
  # match against the configured admin → no auto-promotion → falls
  # through to agent-direct (no TTY in this $() context) → denied.
  out="$(BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
    run_create dev_test --engine claude --dry-run)"
  smoke_assert_contains "$out" "caller source agent-direct is not allowed to mutate system config" \
    "T3: anonymous session is denied"
}

assert_unconfigured_admin_session_denied() {
  reset_runtime
  # Empty roster + no env admin id. Even with BRIDGE_AGENT_ID set, the
  # signal match requires BOTH sides to be non-empty; an unset/empty
  # admin id must NOT collapse the comparison to "" == "" and silently
  # auto-promote.
  write_empty_roster
  local out
  out="$(BRIDGE_AGENT_ID="$ADMIN" \
    run_create dev_test --engine claude --dry-run)"
  smoke_assert_contains "$out" "caller source agent-direct is not allowed to mutate system config" \
    "T4: BRIDGE_AGENT_ID set but no admin configured is denied"
}

assert_non_admin_forged_source_denied() {
  reset_runtime
  write_admin_roster
  local out
  # Non-admin agent session FORGING a trusted BRIDGE_CALLER_SOURCE. Issue
  # #1879 PR #1887 r3 resolves an agent session (BRIDGE_AGENT_ID set) by
  # the non-forgeable admin IDENTITY only — a non-admin's inherited
  # operator-tui / operator-trusted-id claim is ignored, so the session
  # stays agent-direct and is denied. This is the security-critical case:
  # the forged claim follows an agent process into ANY bash -c / eval /
  # subshell, so it MUST NOT confer operator trust on a non-admin agent.
  out="$(BRIDGE_AGENT_ID="worker_a" BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
    BRIDGE_CALLER_SOURCE="operator-trusted-id" \
    run_create dev_test --engine claude --dry-run)"
  smoke_assert_contains "$out" "caller source agent-direct is not allowed to mutate system config" \
    "T5: non-admin agent forging operator-trusted-id is still denied (identity wins, #1879 r3)"
  # operator-tui claim — same outcome, denied.
  out="$(BRIDGE_AGENT_ID="worker_a" BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
    BRIDGE_CALLER_SOURCE="operator-tui" \
    run_create dev_test --engine claude --dry-run)"
  smoke_assert_contains "$out" "caller source agent-direct is not allowed to mutate system config" \
    "T5: non-admin agent forging operator-tui is still denied (identity wins, #1879 r3)"
}

assert_admin_identity_wins_over_stray_source() {
  reset_runtime
  write_admin_roster
  local out
  # Admin session AND a stray/bogus BRIDGE_CALLER_SOURCE. Issue #1879
  # PR #1887 r3 — the admin agent's trust is its non-forgeable identity
  # (BRIDGE_AGENT_ID == BRIDGE_ADMIN_AGENT_ID), NOT the forgeable
  # BRIDGE_CALLER_SOURCE env claim. A stray inherited value must NOT
  # demote the admin (the admin has no need to set a source — it never
  # forges one), so the create plan still reaches the dry-run path.
  out="$(BRIDGE_AGENT_ID="$ADMIN" BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
    BRIDGE_CALLER_SOURCE="definitely-not-trusted" \
    run_create dev_test --engine claude --dry-run)"
  smoke_assert_not_contains "$out" "not allowed to mutate system config" \
    "T6: admin identity is honored even with a stray BRIDGE_CALLER_SOURCE (#1879 r3)"
  smoke_assert_contains "$out" "agent: dev_test" \
    "T6: admin-session create reaches the create plan path despite stray source"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "T1: admin session auto-promoted + audit event"      assert_admin_session_auto_promoted
  smoke_run "T2: non-admin session still denied"                 assert_non_admin_session_denied
  smoke_run "T3: anonymous session still denied"                 assert_anonymous_session_denied
  smoke_run "T4: no admin configured still denied"               assert_unconfigured_admin_session_denied
  smoke_run "T5: non-admin forged trusted source still denied"   assert_non_admin_forged_source_denied
  smoke_run "T6: admin identity wins over stray source"          assert_admin_identity_wins_over_stray_source

  smoke_log "PASS"
}

main "$@"
