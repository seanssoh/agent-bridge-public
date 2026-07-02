#!/usr/bin/env bash
#
# scripts/smoke/token-updater-daemon-tick.sh — #21895 phase-1 (sub-PR 4/4).
#
# Contract C (the daemon lease lifecycle tick). bridge-daemon.sh gained:
#   * bridge_daemon_token_lease_state_file / _due — cadence gate on
#     BRIDGE_USAGE_MONITOR_INTERVAL_SECONDS (default 300s, < the 15-min lease
#     TTL), cloned from the periodic-token-sync cadence contract.
#   * bridge_daemon_token_lease_tick — the lifecycle owner: cheap default-OFF
#     `lease status --check` early-skip, then checkout-if-needed + heartbeat
#     driven by the durable lease-state file. RE-CHECKOUT on: no live lease,
#     lease_expires_at passed, active/local mapping drift, or a heartbeat that
#     returns HTTP 404 (gone) / 409 (bound elsewhere) — codex Q5.
#   * bridge_daemon_token_lease_checkin_on_exit — bounded best-effort check-in
#     FOLDED into the existing _bridge_daemon_on_exit EXIT trap (never a second
#     competing trap); a no-op when disabled and never wedges shutdown.
#
# This smoke exercises the extracted functions directly against a shim
# bridge-auth.sh (emulating the Contract-A lease verbs) and the REAL
# bridge-daemon-helpers.py lease-status-parse / lease-heartbeat-parse
# commands. We do NOT boot the daemon or touch the network. The load-bearing
# invariant proven first: with the lease DISABLED the tick is a byte-for-byte
# no-op (no subprocess beyond the cheap check, no audit row, no state file).
#
# Footgun #11 mitigation: every helper body (shim + driver) lives in a
# committed fixture file under scripts/smoke/fixtures/token-updater-daemon-tick/
# and is copied in via `cp`, never heredoc-written.

# Bash 4+ re-exec (mirrors scripts/smoke/daemon-periodic-token-sync.sh).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:token-updater-daemon-tick] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="token-updater-daemon-tick"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

DAEMON_SRC="$SMOKE_REPO_ROOT/bridge-daemon.sh"
[[ -f "$DAEMON_SRC" ]] || smoke_fail "bridge-daemon.sh not found at $DAEMON_SRC"

# Extract the functions under test (state-file + due + tick + checkout helper
# + exit-trap checkin). tick calls the checkout helper, so pull it too.
FUNCS_SH="$SMOKE_TMP_ROOT/lease-functions.sh"
{
  awk '/^bridge_daemon_token_lease_state_file\(\) \{/,/^}/' "$DAEMON_SRC"
  printf '\n'
  awk '/^bridge_daemon_token_lease_due\(\) \{/,/^}/' "$DAEMON_SRC"
  printf '\n'
  awk '/^bridge_daemon_token_lease_checkout\(\) \{/,/^}/' "$DAEMON_SRC"
  printf '\n'
  awk '/^bridge_daemon_token_lease_tick\(\) \{/,/^}/' "$DAEMON_SRC"
  printf '\n'
  awk '/^bridge_daemon_token_lease_checkin_on_exit\(\) \{/,/^}/' "$DAEMON_SRC"
} >"$FUNCS_SH"

for fn in bridge_daemon_token_lease_state_file \
          bridge_daemon_token_lease_due \
          bridge_daemon_token_lease_checkout \
          bridge_daemon_token_lease_tick \
          bridge_daemon_token_lease_checkin_on_exit; do
  if ! grep -q "^${fn}() {" "$FUNCS_SH"; then
    smoke_fail "could not extract function: $fn (check bridge-daemon.sh for rename)"
  fi
done

# Assert the tick is REGISTERED in the main loop, else a live daemon would
# never call it (a silently-dead feature). Match the LAST_STEP marker + call.
grep -q 'BRIDGE_DAEMON_LAST_STEP="token_updater_lease"' "$DAEMON_SRC" \
  || smoke_fail "tick not registered in the daemon main loop (missing LAST_STEP marker)"
grep -q 'if bridge_daemon_token_lease_tick; then' "$DAEMON_SRC" \
  || smoke_fail "tick not invoked in the daemon main loop"

# Assert the exit-trap check-in is FOLDED into _bridge_daemon_on_exit (NOT a
# second competing `trap … EXIT`, which bash would silently replace). The only
# EXIT trap must remain the single _bridge_daemon_on_exit registration.
grep -q 'bridge_daemon_token_lease_checkin_on_exit' "$DAEMON_SRC" \
  || smoke_fail "exit-trap check-in not present"
# The daemon-lifecycle EXIT trap must remain the SINGLE _bridge_daemon_on_exit
# registration — the check-in is FOLDED into that handler, never a competing
# `trap … EXIT` (bash keeps only one, so a second would silently drop the
# pid-file cleanup + telemetry). Other unrelated `trap "rm -f …" EXIT` in
# helper functions are fine; we assert on the lifecycle trap specifically.
lifecycle_trap_count="$(grep -cE "trap[[:space:]]+'_bridge_daemon_on_exit'[[:space:]]+EXIT" "$DAEMON_SRC" || true)"
[[ "$lifecycle_trap_count" == "1" ]] \
  || smoke_fail "expected exactly one '_bridge_daemon_on_exit' EXIT trap, found $lifecycle_trap_count (a competing trap would drop pid-file cleanup)"
# The check-in must be FOLDED INTO _bridge_daemon_on_exit (a call within the
# function body), not a separate competing `trap … EXIT`. Capture the function
# body into a variable FIRST, then match with a bash `case` glob — do NOT pipe
# awk straight into `grep -q`, and do NOT feed a here-string to grep either.
# Under `set -o pipefail`, `grep -q` exits on its first match and closes the read
# end of the pipe while awk is still emitting the rest of the function body; awk
# then dies with SIGPIPE and pipefail turns the whole pipeline non-zero,
# producing a spurious "not folded" failure. That bit CI shard-3 (mawk + GNU
# grep -q; the source file was byte-identical to a passing local run, so it was
# purely the pipeline's broken-pipe behavior, not the assertion target) — #2248.
# A command-substitution capture + `case` glob avoids the pipe (SIGPIPE-immune,
# engine-independent) AND the `<<<` here-string (no heredoc-ban H3 site — footgun
# #11 lint). `case`'s `*…*` matches across newlines, so the multiline body is fine.
trap_body="$(awk '/^_bridge_daemon_on_exit\(\) \{/,/^}/' "$DAEMON_SRC")"
case "$trap_body" in
  *bridge_daemon_token_lease_checkin_on_exit*) : ;;  # folded into the handler — good
  *) smoke_fail "check-in must be folded INTO _bridge_daemon_on_exit, not a separate trap" ;;
esac

# Shim dir: the function bodies find bridge-auth.sh + bridge-daemon-helpers.py
# via "$SCRIPT_DIR/...", so we point SCRIPT_DIR (in the driver) at this dir.
SHIM_DIR="$SMOKE_TMP_ROOT/shim"
mkdir -p "$SHIM_DIR"

FIXTURE_DIR="$SMOKE_REPO_ROOT/scripts/smoke/fixtures/token-updater-daemon-tick"
[[ -d "$FIXTURE_DIR" ]] || smoke_fail "fixture dir not found: $FIXTURE_DIR"

cp "$FIXTURE_DIR/bridge-auth-shim.sh" "$SHIM_DIR/bridge-auth.sh"
chmod +x "$SHIM_DIR/bridge-auth.sh"
# Re-use the REAL daemon-helpers so the lease-status-parse / lease-heartbeat-
# parse contract is exercised end-to-end (symlink, not a re-implementation).
ln -sf "$SMOKE_REPO_ROOT/bridge-daemon-helpers.py" "$SHIM_DIR/bridge-daemon-helpers.py"

DRIVER="$SMOKE_TMP_ROOT/driver.sh"
cp "$FIXTURE_DIR/driver.sh" "$DRIVER"
chmod +x "$DRIVER"

AUDIT_FILE="$SMOKE_TMP_ROOT/audit.log"
LEASE_SHIM_STATE="$SMOKE_TMP_ROOT/lease-shim-state.env"  # noqa: iso-helper-boundary - controller-only smoke temp fixture filename, not a cross-agent .env read
LEASE_SHIM_CALLS="$SMOKE_TMP_ROOT/lease-shim-calls.log"
: >"$AUDIT_FILE"
: >"$LEASE_SHIM_STATE"
: >"$LEASE_SHIM_CALLS"

# Write the shim scenario for the next driver invocation. Args are k=v pairs.
set_scenario() {
  : >"$LEASE_SHIM_STATE"
  local pair
  for pair in "$@"; do
    printf '%s\n' "$pair" >>"$LEASE_SHIM_STATE"
  done
}

ARGV_LOG="$SMOKE_TMP_ROOT/with-timeout-argv.log"
: >"$ARGV_LOG"

run_driver() {
  local action="$1"
  local interval="${2:-300}"
  env \
      SHIM_DIR="$SHIM_DIR" \
      BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
      FUNCS_SH="$FUNCS_SH" \
      AUDIT_FILE="$AUDIT_FILE" \
      LEASE_SHIM_STATE="$LEASE_SHIM_STATE" \
      LEASE_SHIM_CALLS="$LEASE_SHIM_CALLS" \
      WITH_TIMEOUT_ARGV_LOG="${WITH_TIMEOUT_ARGV_LOG:-}" \
      BRIDGE_USAGE_MONITOR_INTERVAL_SECONDS="$interval" \
      bash "$DRIVER" "$action" 2>/dev/null | tail -n 1
}

assert_marker() {
  smoke_assert_eq "$2" "$1" "$3"
}

STATE_FILE="$(run_driver state-file)"
[[ -n "$STATE_FILE" ]] || smoke_fail "could not resolve state file path from driver"

audit_rows() { grep -c "^action=$1 " "$AUDIT_FILE" 2>/dev/null || true; }
last_tick_row() { grep "^action=claude_token_lease_tick " "$AUDIT_FILE" 2>/dev/null | tail -n 1; }
calls_count() { grep -c "^$1$" "$LEASE_SHIM_CALLS" 2>/dev/null || true; }

reset_run_state() {
  rm -f "$STATE_FILE"
  : >"$AUDIT_FILE"
  : >"$LEASE_SHIM_CALLS"
}

# ── B1: disabled → byte-for-byte no-op ────────────────────────────────
step_b1_disabled_noop() {
  smoke_log "B1: lease DISABLED — tick is a no-op (no state file, no audit)"
  reset_run_state
  set_scenario "LEASE_ENABLED=0"
  assert_marker "$(run_driver tick 300)" "TICK-FAIL" "B1 tick returns not-fired when disabled"
  [[ ! -f "$STATE_FILE" ]] || smoke_fail "B1: disabled tick must NOT create a state file"
  smoke_assert_eq "0" "$(audit_rows claude_token_lease_tick)" "B1: no tick audit row when disabled"
  smoke_assert_eq "0" "$(audit_rows claude_token_lease_checkout)" "B1: no checkout audit row when disabled"
  # Only the cheap status --check probe ran; no status-json/checkout/heartbeat.
  smoke_assert_eq "0" "$(calls_count status-json)" "B1: no status --json when disabled"
  smoke_assert_eq "0" "$(calls_count checkout)" "B1: no checkout when disabled"
  smoke_assert_eq "0" "$(calls_count heartbeat)" "B1: no heartbeat when disabled"
}

# ── B2: enabled, no live lease → checkout ─────────────────────────────
step_b2_no_lease_checks_out() {
  smoke_log "B2: enabled + no live lease → checkout"
  reset_run_state
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1" "LEASE_HAS_LEASE=0" \
    "LEASE_SERVICE_TOKEN_ID=svc-1" "LEASE_CHECKOUT_STATUS=ok"
  assert_marker "$(run_driver tick 300)" "TICK-OK" "B2 tick fires"
  [[ -f "$STATE_FILE" ]] || smoke_fail "B2: state file written after enabled tick"
  smoke_assert_eq "1" "$(calls_count checkout)" "B2: exactly one checkout"
  smoke_assert_eq "0" "$(calls_count heartbeat)" "B2: no heartbeat when checking out"
  smoke_assert_contains "$(last_tick_row)" "status=checked_out" "B2: tick audits checked_out"
  smoke_assert_contains "$(last_tick_row)" "reason=no_lease" "B2: reason=no_lease"
}

# ── B3: live lease, expired → re-checkout ─────────────────────────────
step_b3_expired_rechecks_out() {
  smoke_log "B3: live lease past lease_expires_at → re-checkout"
  reset_run_state
  local past; past="$(( $(date +%s) - 60 ))"
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1" "LEASE_HAS_LEASE=1" \
    "LEASE_EXPIRES_AT=$past" "LEASE_LOCAL_TOKEN_ID=tok-a" "LEASE_ACTIVE_TOKEN_ID=tok-a" \
    "LEASE_SERVICE_TOKEN_ID=svc-1" "LEASE_CHECKOUT_STATUS=ok"
  assert_marker "$(run_driver tick 300)" "TICK-OK" "B3 tick fires"
  smoke_assert_eq "1" "$(calls_count checkout)" "B3: one checkout on expiry"
  smoke_assert_eq "0" "$(calls_count heartbeat)" "B3: no heartbeat on expiry (re-checkout wins)"
  smoke_assert_contains "$(last_tick_row)" "reason=lease_expired" "B3: reason=lease_expired"
}

# ── B4: live, unexpired lease, active/local drift → re-checkout ───────
step_b4_drift_rechecks_out() {
  smoke_log "B4: active_token_id != lease local_token_id → re-checkout"
  reset_run_state
  local future; future="$(( $(date +%s) + 900 ))"
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1" "LEASE_HAS_LEASE=1" \
    "LEASE_EXPIRES_AT=$future" "LEASE_LOCAL_TOKEN_ID=tok-a" "LEASE_ACTIVE_TOKEN_ID=tok-b" \
    "LEASE_SERVICE_TOKEN_ID=svc-1" "LEASE_CHECKOUT_STATUS=ok"
  assert_marker "$(run_driver tick 300)" "TICK-OK" "B4 tick fires"
  smoke_assert_eq "1" "$(calls_count checkout)" "B4: one checkout on drift"
  smoke_assert_eq "0" "$(calls_count heartbeat)" "B4: no heartbeat on drift"
  smoke_assert_contains "$(last_tick_row)" "reason=mapping_drift" "B4: reason=mapping_drift"
}

# ── B5: healthy lease, heartbeat 404 → re-checkout ────────────────────
step_b5_heartbeat_404_rechecks_out() {
  smoke_log "B5: heartbeat http=404 (lease gone) → re-checkout"
  reset_run_state
  local future; future="$(( $(date +%s) + 900 ))"
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1" "LEASE_HAS_LEASE=1" \
    "LEASE_EXPIRES_AT=$future" "LEASE_LOCAL_TOKEN_ID=tok-a" "LEASE_ACTIVE_TOKEN_ID=tok-a" \
    "LEASE_SERVICE_TOKEN_ID=svc-1" "LEASE_HEARTBEAT_STATUS=error" "LEASE_HEARTBEAT_HTTP=404" \
    "LEASE_CHECKOUT_STATUS=ok"
  assert_marker "$(run_driver tick 300)" "TICK-OK" "B5 tick fires"
  smoke_assert_eq "1" "$(calls_count heartbeat)" "B5: heartbeat attempted first"
  smoke_assert_eq "1" "$(calls_count checkout)" "B5: re-checkout after 404"
  smoke_assert_contains "$(last_tick_row)" "reason=heartbeat_404" "B5: reason=heartbeat_404"
}

# ── B6: healthy lease, heartbeat 409 → re-checkout ────────────────────
step_b6_heartbeat_409_rechecks_out() {
  smoke_log "B6: heartbeat http=409 (bound elsewhere) → re-checkout"
  reset_run_state
  local future; future="$(( $(date +%s) + 900 ))"
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1" "LEASE_HAS_LEASE=1" \
    "LEASE_EXPIRES_AT=$future" "LEASE_LOCAL_TOKEN_ID=tok-a" "LEASE_ACTIVE_TOKEN_ID=tok-a" \
    "LEASE_SERVICE_TOKEN_ID=svc-1" "LEASE_HEARTBEAT_STATUS=conflict" "LEASE_HEARTBEAT_HTTP=409" \
    "LEASE_CHECKOUT_STATUS=ok"
  assert_marker "$(run_driver tick 300)" "TICK-OK" "B6 tick fires"
  smoke_assert_eq "1" "$(calls_count heartbeat)" "B6: heartbeat attempted first"
  smoke_assert_eq "1" "$(calls_count checkout)" "B6: re-checkout after 409"
  smoke_assert_contains "$(last_tick_row)" "reason=heartbeat_409" "B6: reason=heartbeat_409"
}

# ── B7: healthy lease, heartbeat ok → NO checkout ─────────────────────
step_b7_healthy_heartbeat_only() {
  smoke_log "B7: healthy, correctly-mapped lease → heartbeat only (no checkout)"
  reset_run_state
  local future; future="$(( $(date +%s) + 900 ))"
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1" "LEASE_HAS_LEASE=1" \
    "LEASE_EXPIRES_AT=$future" "LEASE_LOCAL_TOKEN_ID=tok-a" "LEASE_ACTIVE_TOKEN_ID=tok-a" \
    "LEASE_SERVICE_TOKEN_ID=svc-1" "LEASE_HEARTBEAT_STATUS=ok" "LEASE_HEARTBEAT_HTTP=200"
  assert_marker "$(run_driver tick 300)" "TICK-OK" "B7 tick fires"
  smoke_assert_eq "1" "$(calls_count heartbeat)" "B7: heartbeat runs"
  smoke_assert_eq "0" "$(calls_count checkout)" "B7: NO checkout on a healthy lease"
  smoke_assert_contains "$(last_tick_row)" "reason=heartbeat" "B7: reason=heartbeat"
  smoke_assert_contains "$(last_tick_row)" "status=ok" "B7: heartbeat status ok"
}

# ── B8: cadence gate — immediate second call not-due → no-op ──────────
step_b8_cadence_gate() {
  smoke_log "B8: immediate second call is NOT-DUE → tick no-ops"
  reset_run_state
  local future; future="$(( $(date +%s) + 900 ))"
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1" "LEASE_HAS_LEASE=1" \
    "LEASE_EXPIRES_AT=$future" "LEASE_LOCAL_TOKEN_ID=tok-a" "LEASE_ACTIVE_TOKEN_ID=tok-a" \
    "LEASE_SERVICE_TOKEN_ID=svc-1" "LEASE_HEARTBEAT_STATUS=ok" "LEASE_HEARTBEAT_HTTP=200"
  # Prime the state file (first call fires).
  assert_marker "$(run_driver tick 300)" "TICK-OK" "B8 first call fires"
  local first_ts; first_ts="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
  local hb_before; hb_before="$(calls_count heartbeat)"
  # Second call: due-check must be NOT-DUE (elapsed << interval).
  assert_marker "$(run_driver due 300)" "NOT-DUE" "B8 due-check not-due right after"
  assert_marker "$(run_driver tick 300)" "TICK-FAIL" "B8 second call no-ops (not due)"
  smoke_assert_eq "$first_ts" "$(cat "$STATE_FILE" 2>/dev/null || echo 0)" "B8: state ts unchanged when not-due"
  smoke_assert_eq "$hb_before" "$(calls_count heartbeat)" "B8: no extra heartbeat when not-due"
}

# ── B9: unparseable lease status → skip this tick ─────────────────────
step_b9_status_parse_error_skips() {
  smoke_log "B9: unparseable lease status --json → skip (no checkout/heartbeat)"
  reset_run_state
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1" "LEASE_STATUS_BAD=1"
  assert_marker "$(run_driver tick 300)" "TICK-FAIL" "B9 tick skips on parse error"
  smoke_assert_eq "0" "$(calls_count checkout)" "B9: no checkout on parse error"
  smoke_assert_eq "0" "$(calls_count heartbeat)" "B9: no heartbeat on parse error"
  smoke_assert_contains "$(last_tick_row)" "reason=status_parse_error" "B9: reason=status_parse_error"
}

# ── B10: exit-trap check-in — disabled no-op vs enabled call ──────────
step_b10_exit_checkin() {
  smoke_log "B10: exit-trap check-in — no-op when disabled, calls checkin when enabled"
  # Disabled: no checkin call.
  reset_run_state
  set_scenario "LEASE_ENABLED=0"
  assert_marker "$(run_driver checkin)" "CHECKIN-DONE" "B10 checkin returns cleanly when disabled"
  smoke_assert_eq "0" "$(calls_count checkin)" "B10: no checkin call when disabled"
  # Enabled: checkin is attempted.
  reset_run_state
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1"
  assert_marker "$(run_driver checkin)" "CHECKIN-DONE" "B10 checkin returns cleanly when enabled"
  smoke_assert_eq "1" "$(calls_count checkin)" "B10: exactly one checkin call when enabled"
}

# ── B11: checkout secret_material NEVER transits parser argv (codex #2248 P1) ─
step_b11_checkout_secret_never_in_argv() {
  smoke_log "B11: checkout envelope secret_material never reaches parser argv (codex #2248 finding 2, P1)"
  reset_run_state
  local marker="SEKRIT-CHECKOUT-MATERIAL-MUST-NOT-LEAK"
  # Enable the argv proxy for THIS case only, then capture what the daemon execs.
  WITH_TIMEOUT_ARGV_LOG="$ARGV_LOG"
  : >"$ARGV_LOG"
  # No live lease → the tick takes the checkout path; the shim returns an ok
  # envelope CARRYING secret_material.
  set_scenario "LEASE_ENABLED=1" "LEASE_CONFIGURED=1" "LEASE_HAS_LEASE=0" \
    "LEASE_SERVICE_TOKEN_ID=svc-1" "LEASE_CHECKOUT_STATUS=ok" "LEASE_CHECKOUT_SECRET=$marker"
  assert_marker "$(run_driver tick 300)" "TICK-OK" "B11 tick fires (checkout path)"
  WITH_TIMEOUT_ARGV_LOG=""
  smoke_assert_eq "1" "$(calls_count checkout)" "B11: exactly one checkout"
  # The checkout still SUCCEEDED — proving the status was parsed from STDIN (the
  # secret-bearing envelope was delivered, just not via argv).
  smoke_assert_contains "$(last_tick_row)" "status=checked_out" "B11: checkout succeeded via stdin-delivered envelope"
  # THE P1 GUARD: the secret marker must appear in NO subprocess argv the daemon
  # built. A revert to `sync-status-parse "$checkout_json"` would leak it here.
  if grep -q "$marker" "$ARGV_LOG" 2>/dev/null; then
    smoke_fail "B11: secret_material LEAKED into subprocess argv (ps/proc-visible): $(grep "$marker" "$ARGV_LOG" | head -n1)"
  fi
  # And the checkout-status parser must be the STDIN verb, invoked with NO JSON
  # positional after it (belt-and-suspenders against a positional-arg regression).
  grep -q 'lease-checkout-status-parse' "$ARGV_LOG" \
    || smoke_fail "B11: expected the stdin verb 'lease-checkout-status-parse' in the checkout path (argv log)"
  if grep 'lease-checkout-status-parse' "$ARGV_LOG" | grep -q '{'; then
    smoke_fail "B11: checkout-status parser argv carried a JSON blob — secret-in-argv regression"
  fi
}

smoke_run "B1 disabled tick is a byte-for-byte no-op" step_b1_disabled_noop
smoke_run "B2 no live lease checks out" step_b2_no_lease_checks_out
smoke_run "B3 expired lease re-checks out" step_b3_expired_rechecks_out
smoke_run "B4 active/local drift re-checks out" step_b4_drift_rechecks_out
smoke_run "B5 heartbeat 404 re-checks out" step_b5_heartbeat_404_rechecks_out
smoke_run "B6 heartbeat 409 re-checks out" step_b6_heartbeat_409_rechecks_out
smoke_run "B7 healthy lease heartbeats only" step_b7_healthy_heartbeat_only
smoke_run "B8 cadence gate blocks immediate re-tick" step_b8_cadence_gate
smoke_run "B9 status parse error skips the tick" step_b9_status_parse_error_skips
smoke_run "B10 exit-trap check-in is bounded + gated" step_b10_exit_checkin
smoke_run "B11 checkout secret_material never transits parser argv" step_b11_checkout_secret_never_in_argv
