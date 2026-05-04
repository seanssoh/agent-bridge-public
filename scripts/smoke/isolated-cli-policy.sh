#!/usr/bin/env bash
# scripts/smoke/isolated-cli-policy.sh — Issue #544 PR4 smoke.
#
# Validates the curated bin/agb shim's isolated-UID subcommand
# allowlist + audit row writer (added by PR4). Coverage:
#
# 1. Allowlist subcommands (inbox, show, claim, done, summary, create)
#    pass through to the underlying ${BRIDGE_HOME}/agb when invoked from
#    an isolated UID context (BRIDGE_GATEWAY_PROXY=1 + UID mismatch),
#    and an `decision: "allow"` audit row appears.
# 2. Anything-not-allowed (admin, kill, agent restart, cron create,
#    config set, wave dispatch — sample of the default-deny set) exits
#    64 with a clean message and writes a `decision: "deny"` audit row.
# 3. Non-isolated invocation (BRIDGE_GATEWAY_PROXY unset, OR UID matches
#    BRIDGE_CONTROLLER_UID) skips the gate entirely — no audit row, all
#    subcommands pass to the underlying agb.
# 4. Audit redaction: arg VALUES never appear in the audit row, only
#    arg_count. A subcommand carrying a fake task ID + private note must
#    leave neither in the JSONL row.
#
# Does NOT exercise:
#   - live `bridge_write_linux_agent_env_file` emission of
#     BRIDGE_CONTROLLER_UID under sudo (requires `agent-bridge isolate`
#     against a real linux-user UID).
#   - real allowlisted `agb` subcommand semantics (queue, db, etc.).
#     Those are covered by the queue / agent-update smokes.

set -euo pipefail

SMOKE_NAME="isolated-cli-policy"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

build_fixture() {
  smoke_make_temp_root "$SMOKE_NAME"
  FIXTURE_HOME="$SMOKE_TMP_ROOT/bridge-home"
  mkdir -p "$FIXTURE_HOME/bin" "$FIXTURE_HOME/logs/agents/test-agent"
  cp "$SMOKE_REPO_ROOT/bin/agb" "$FIXTURE_HOME/bin/agb"
  chmod +x "$FIXTURE_HOME/bin/agb"

  # Stub root agb that records its argv so we can assert the shim's
  # gate let the call through.
  STUB_LOG="$SMOKE_TMP_ROOT/stub-agb.log"
  cat >"$FIXTURE_HOME/agb" <<EOF
#!/usr/bin/env bash
printf 'INVOKED:%s\n' "\$*" >>"$STUB_LOG"
exit 0
EOF
  chmod +x "$FIXTURE_HOME/agb"

  AUDIT_LOG="$FIXTURE_HOME/logs/agents/test-agent/audit.jsonl"
}

# Real UID at smoke run time. We pick a deliberately mismatched
# BRIDGE_CONTROLLER_UID so the policy gate fires. Using a constant
# (e.g. 99999) would collide on systems where the smoke happens to
# run as that UID; instead derive a guaranteed-different value.
mismatched_controller_uid() {
  local self_uid
  self_uid="$(id -u)"
  if (( self_uid == 0 )); then
    printf '%s' "12345"
  else
    printf '%s' "$(( self_uid + 1 ))"
  fi
}

run_isolated_shim() {
  # $@ becomes the shim's argv. Caller wraps with isolated env.
  local controller_uid
  controller_uid="$(mismatched_controller_uid)"
  env -i \
    PATH="/usr/bin:/bin" \
    HOME="$SMOKE_TMP_ROOT" \
    BRIDGE_HOME="$FIXTURE_HOME" \
    BRIDGE_GATEWAY_PROXY=1 \
    BRIDGE_CONTROLLER_UID="$controller_uid" \
    BRIDGE_AGENT_ID=test-agent \
    bash "$FIXTURE_HOME/bin/agb" "$@"
}

run_non_isolated_shim() {
  # No BRIDGE_GATEWAY_PROXY → gate doesn't fire.
  env -i \
    PATH="/usr/bin:/bin" \
    HOME="$SMOKE_TMP_ROOT" \
    BRIDGE_HOME="$FIXTURE_HOME" \
    BRIDGE_AGENT_ID=test-agent \
    bash "$FIXTURE_HOME/bin/agb" "$@"
}

run_uid_match_shim() {
  # BRIDGE_GATEWAY_PROXY=1 but BRIDGE_CONTROLLER_UID matches our UID →
  # gate doesn't fire (operator forgot to drop the env from their own
  # shell).
  local self_uid
  self_uid="$(id -u)"
  env -i \
    PATH="/usr/bin:/bin" \
    HOME="$SMOKE_TMP_ROOT" \
    BRIDGE_HOME="$FIXTURE_HOME" \
    BRIDGE_GATEWAY_PROXY=1 \
    BRIDGE_CONTROLLER_UID="$self_uid" \
    BRIDGE_AGENT_ID=test-agent \
    bash "$FIXTURE_HOME/bin/agb" "$@"
}

last_audit_row() {
  [[ -f "$AUDIT_LOG" ]] || return 0
  tail -n 1 "$AUDIT_LOG"
}

assert_allowlist_passes_through() {
  local subcmd
  for subcmd in inbox show claim done summary create; do
    : >"$STUB_LOG"
    : >"$AUDIT_LOG"
    run_isolated_shim "$subcmd" "arg-1" "arg-2"
    smoke_assert_contains "$(cat "$STUB_LOG")" "INVOKED:$subcmd arg-1 arg-2" \
      "allowlist '$subcmd' delegates to underlying agb"
    local row
    row="$(last_audit_row)"
    smoke_assert_contains "$row" "\"subcommand\":\"$subcmd\"" \
      "allowlist '$subcmd' audit row carries subcommand name"
    smoke_assert_contains "$row" '"decision":"allow"' \
      "allowlist '$subcmd' audit row marks decision=allow"
    smoke_assert_contains "$row" '"reason":"allowlist"' \
      "allowlist '$subcmd' audit row reason=allowlist"
    smoke_assert_contains "$row" '"arg_count":2' \
      "allowlist '$subcmd' audit row reports arg_count without values"
  done
}

assert_denylist_blocks_with_exit_64() {
  # A representative slice of the default-deny set. The shim does not
  # enumerate denied subcommands — anything not on the allowlist is
  # denied. Pick across the operator-class surface to confirm.
  local rc=0 stderr_capture
  for subcmd in admin kill upgrade attach urgent setup isolate worktree audit; do
    : >"$STUB_LOG"
    : >"$AUDIT_LOG"
    rc=0
    stderr_capture="$(run_isolated_shim "$subcmd" 2>&1 1>/dev/null)" || rc=$?
    smoke_assert_eq "64" "$rc" \
      "denylist '$subcmd' exits 64"
    smoke_assert_contains "$stderr_capture" "is not allowed for isolated agents" \
      "denylist '$subcmd' surfaces clean deny message"
    smoke_assert_contains "$stderr_capture" "agb create --to admin" \
      "denylist '$subcmd' suggests queue route"
    smoke_assert_eq "" "$(cat "$STUB_LOG")" \
      "denylist '$subcmd' does NOT delegate to underlying agb"
    local row
    row="$(last_audit_row)"
    smoke_assert_contains "$row" "\"subcommand\":\"$subcmd\"" \
      "denylist '$subcmd' audit row carries subcommand name"
    smoke_assert_contains "$row" '"decision":"deny"' \
      "denylist '$subcmd' audit row marks decision=deny"
    smoke_assert_contains "$row" '"reason":"not_on_isolated_allowlist"' \
      "denylist '$subcmd' audit row reason=not_on_isolated_allowlist"
  done
}

assert_non_isolated_skips_gate() {
  # Without BRIDGE_GATEWAY_PROXY the policy gate is disabled, so even
  # operator-class subcommands pass through and NO audit row is written.
  local subcmd
  for subcmd in inbox admin kill upgrade attach create; do
    : >"$STUB_LOG"
    : >"$AUDIT_LOG"
    run_non_isolated_shim "$subcmd" "arg"
    smoke_assert_contains "$(cat "$STUB_LOG")" "INVOKED:$subcmd arg" \
      "non-isolated '$subcmd' delegates without policy"
    local audit_size
    audit_size="$(wc -c <"$AUDIT_LOG" | tr -d ' ')"
    smoke_assert_eq "0" "$audit_size" \
      "non-isolated '$subcmd' writes NO audit row"
  done
}

assert_uid_match_skips_gate() {
  # BRIDGE_GATEWAY_PROXY=1 but UID matches BRIDGE_CONTROLLER_UID — this
  # is the "operator manually exported the proxy flag in their own
  # shell" case. Gate must NOT fire.
  : >"$STUB_LOG"
  : >"$AUDIT_LOG"
  run_uid_match_shim admin --some-arg
  smoke_assert_contains "$(cat "$STUB_LOG")" "INVOKED:admin --some-arg" \
    "UID-matching invocation bypasses policy even with BRIDGE_GATEWAY_PROXY=1"
  local audit_size
  audit_size="$(wc -c <"$AUDIT_LOG" | tr -d ' ')"
  smoke_assert_eq "0" "$audit_size" \
    "UID-matching invocation writes NO audit row"
}

assert_audit_redaction_drops_arg_values() {
  # Args carrying a fake task ID + private note must NOT appear in the
  # audit row. Only arg_count is captured.
  : >"$STUB_LOG"
  : >"$AUDIT_LOG"
  local secret_token="task-secret-id-12345"
  local private_note="private notes operator wouldnt want logged"
  run_isolated_shim done "$secret_token" --agent self --note "$private_note"

  local row
  row="$(last_audit_row)"
  smoke_assert_contains "$row" '"subcommand":"done"' \
    "audit redaction: subcommand name preserved"
  smoke_assert_contains "$row" '"arg_count":5' \
    "audit redaction: arg_count reflects positional + flags (token + --agent + self + --note + note-text)"
  smoke_assert_not_contains "$row" "$secret_token" \
    "audit redaction: secret task-id NOT emitted"
  smoke_assert_not_contains "$row" "private notes" \
    "audit redaction: private note text NOT emitted"
  smoke_assert_not_contains "$row" "--agent" \
    "audit redaction: flag names NOT emitted (only arg_count)"
}

main() {
  build_fixture

  smoke_run "allowlist subcommands pass through with allow audit" \
    assert_allowlist_passes_through
  smoke_run "denylist subcommands exit 64 with deny audit" \
    assert_denylist_blocks_with_exit_64
  smoke_run "non-isolated invocation skips policy + audit" \
    assert_non_isolated_skips_gate
  smoke_run "UID-matching invocation skips policy even with proxy flag" \
    assert_uid_match_skips_gate
  smoke_run "audit row redacts arg values (arg_count only)" \
    assert_audit_redaction_drops_arg_values

  smoke_log "PASS"
}

main "$@"
