#!/usr/bin/env bash
# scripts/smoke/1405-handoffd-supervision.sh — A2A receiver supervision smoke.
#
# Issue #1405: the A2A receiver (bridge-handoffd.py serve) had NO supervisor —
# a silent exit left the listen port unbound with no auto-restart and no
# alarm. This smoke exercises the daemon-as-supervisor tick
# (process_a2a_receiver_supervise_tick in bridge-daemon.sh), the read-only
# healthz serve probe (bridge-handoffd.py healthz), the auto-restart through
# the FULL fail-closed bind proof (bridge-handoff-daemon.sh start), the
# crash-loop cap + alarm, exit-cause capture, the status dashboard alarm row,
# the non-A2A-install silence, and the systemd-defer path.
#
# Loopback harness (BRIDGE_A2A_ALLOW_TEST_BIND=1, free port) reused from
# a2a-cross-bridge.sh. EVERY assertion has teeth: pre-fix (no healthz
# subcommand, no supervise tick) the relevant checks FAIL.

set -euo pipefail

SMOKE_NAME="1405-handoffd-supervision"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HANDOFFD_PID=""

cleanup() {
  # Resume a STOPped receiver before killing so it can clean up its pidfile.
  if [[ -n "$HANDOFFD_PID" ]]; then
    kill -CONT "$HANDOFFD_PID" >/dev/null 2>&1 || true
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  # Also stop any supervisor-spawned receiver via the lifecycle script.
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  smoke_cleanup_temp_root
}
trap cleanup EXIT

A2A_PORT=""
A2A_SECRET="smoke-shared-secret-do-not-use-in-prod-0123456789"

# The receiver test-bind escape hatch + a fast supervise cadence (the tick-
# state is deleted before each sync so the cadence gate never blocks a test
# sync, but a low interval keeps the next-ts window short anyway).
export BRIDGE_A2A_ALLOW_TEST_BIND=1
export BRIDGE_A2A_RECEIVER_SUPERVISE_INTERVAL_SECONDS=1
# Small caps so the crash-loop test runs in a few syncs, not five+ minutes.
export BRIDGE_A2A_RECEIVER_MAX_RESTARTS=3
export BRIDGE_A2A_RECEIVER_RESTART_WINDOW_SECONDS=600
export BRIDGE_A2A_RECEIVER_CRASHLOOP_ADMIN_COOLDOWN_SECONDS=1800
export BRIDGE_A2A_RECEIVER_HEALTHZ_TIMEOUT_SECONDS=2

pick_free_port() {
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" free-port
}

handoffd_pidfile() {
  printf '%s/handoff/handoffd.pid' "$BRIDGE_STATE_DIR"
}

handoffd_log() {
  printf '%s/a2a-handoffd.log' "$BRIDGE_LOG_DIR"
}

supervise_state() {
  printf '%s/handoff/receiver-supervise.env' "$BRIDGE_STATE_DIR"
}

exit_json() {
  printf '%s/handoff/receiver-exit.json' "$BRIDGE_STATE_DIR"
}

# Clear the supervise cadence-throttle so the next `bridge-daemon.sh sync`
# always runs the supervise tick (real time would otherwise gate it).
clear_supervise_throttle() {
  rm -f "$BRIDGE_STATE_DIR/handoff/receiver-supervise-tick.env" 2>/dev/null || true
}

write_loopback_config() {
  local port="$1"
  mkdir -p "$BRIDGE_HOME"
  cat >"$BRIDGE_HOME/handoff.local.json" <<EOF
{
  "bridge_id": "bridge-b",
  "listen": { "address": "127.0.0.1", "port": ${port}, "enqueue_path": "/enqueue" },
  "timestamp_skew_seconds": 300,
  "peers": [
    {
      "id": "bridge-a",
      "address": "127.0.0.1",
      "port": ${port},
      "secret": "${A2A_SECRET}",
      "inbound_allowlist": ["reviewer"],
      "caps": { "max_body_bytes": 262144 }
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff.local.json"
}

# A config whose bind can NEVER pass the fail-closed proof: a tailnet-shaped
# (100.64.0.0/10) address that is NOT a real local interface, with the
# tailscale CLI pointed at a nonexistent path so resolve_bind fails closed
# (no CIDR-shape fallback). Used to force bridge_a2a_receiver_start non-zero.
write_unprovable_config() {
  local port="$1"
  cat >"$BRIDGE_HOME/handoff.local.json" <<EOF
{
  "bridge_id": "bridge-b",
  "listen": { "address": "100.64.0.10", "port": ${port}, "enqueue_path": "/enqueue" },
  "timestamp_skew_seconds": 300,
  "peers": [
    {
      "id": "bridge-a",
      "address": "127.0.0.1",
      "port": ${port},
      "secret": "${A2A_SECRET}",
      "inbound_allowlist": ["reviewer"]
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff.local.json"
}

# Start the receiver through the lifecycle script so the running process
# carries `--pidfile <handoffd.pid>` and the supervisor's process gate
# (bridge_a2a_receiver_running) recognizes it.
start_receiver_via_lifecycle() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" start >/dev/null 2>&1
  local waited=0
  while (( waited < 50 )); do
    if python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  smoke_fail "receiver did not start; log: $(cat "$(handoffd_log)" 2>/dev/null)"
}

receiver_pid_now() {
  cat "$(handoffd_pidfile)" 2>/dev/null || true
}

run_sync() {
  clear_supervise_throttle
  bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" sync 2>&1 || true
}

# --- Check 1: healthz subcommand exists + is green against a live receiver ---
# Pre-fix: the `healthz` subcommand does not exist -> argparse exits 2 with an
# "invalid choice" error, so the exit-0 + "healthy" assertion FAILS.
check_healthz_green() {
  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle

  local out rc=0
  out="$(python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" healthz \
    --config "$BRIDGE_HOME/handoff.local.json" --timeout 3 2>&1)" || rc=$?
  smoke_assert_eq "0" "$rc" "healthz exits 0 against a live loopback receiver"
  smoke_assert_contains "$out" "healthy" "healthz prints 'healthy' when serving"
}

# --- Check 2: healthz detects a wedged (bound-but-not-accepting) serve loop ---
# SIGSTOP freezes the process: the socket stays bound (pid alive) but the serve
# loop cannot accept -> healthz connect/read times out -> non-zero + the
# healthz_timeout reason word. Pre-fix: no probe -> nothing to detect.
check_healthz_detects_wedged() {
  local pid
  pid="$(receiver_pid_now)"
  [[ -n "$pid" ]] || smoke_fail "no receiver pid for wedged-serve probe"
  kill -STOP "$pid" 2>/dev/null || smoke_fail "could not SIGSTOP receiver pid $pid"

  local out rc=0
  out="$(python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" healthz \
    --config "$BRIDGE_HOME/handoff.local.json" --timeout 2 2>&1)" || rc=$?
  # Resume immediately so the process can be reaped in cleanup.
  kill -CONT "$pid" 2>/dev/null || true

  smoke_assert_match "$rc" '^[1-9]' "healthz exits non-zero against a wedged serve loop"
  smoke_assert_contains "$out" "healthz_timeout" \
    "healthz reports healthz_timeout for a bound-but-not-accepting socket"
}

# --- Check 3: auto-restart re-runs the FULL fail-closed bind proof ---
# kill -9 the receiver (process_gone), capture the old pid, run ONE daemon
# sync, and assert a NEW pid is in the pidfile AND the log shows a fresh
# preflight/listening line (proves resolve-then-prove ran on restart).
check_auto_restart_reproves_bind() {
  local old_pid
  old_pid="$(receiver_pid_now)"
  [[ -n "$old_pid" ]] || smoke_fail "no receiver pid for restart test"
  kill -9 "$old_pid" 2>/dev/null || true
  wait "$old_pid" 2>/dev/null || true
  # Confirm the port is actually free (receiver dead) before the sync.
  local waited=0
  while python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    (( waited > 50 )) && break
  done

  # Mark the log boundary so we assert a FRESH preflight/listening after sync.
  local log_before
  log_before="$(wc -l < "$(handoffd_log)" 2>/dev/null || printf '0')"

  run_sync >/dev/null

  # Wait for the supervisor-launched receiver to publish a new pid + listen.
  waited=0
  while (( waited < 50 )); do
    python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null && break
    sleep 0.1
    waited=$((waited + 1))
  done

  local new_pid
  new_pid="$(receiver_pid_now)"
  smoke_assert_match "$new_pid" '^[0-9]+$' "restart published a new receiver pid"
  [[ "$new_pid" != "$old_pid" ]] || smoke_fail "restart pid ($new_pid) equals the killed pid ($old_pid)"

  # The fresh tail of the log must show the receiver listening again — proof
  # the restart went through serve's bind path (which only runs AFTER the
  # fail-closed preflight in bridge_a2a_receiver_start).
  local fresh_tail
  fresh_tail="$(tail -n +"$((log_before + 1))" "$(handoffd_log)" 2>/dev/null || true)"
  smoke_assert_contains "$fresh_tail" "listening" \
    "restart re-ran the bind proof and the receiver is listening again"
}

# --- Check 5: exit-cause captured (run before crash-loop reuses the config) --
# After a kill + restart cycle, receiver-exit.json must exist with a reason and
# a non-empty log_tail. (Ordered before the crash-loop check, which rewrites
# the config.)
check_exit_cause_captured() {
  smoke_assert_file_exists "$(exit_json)" "receiver-exit.json captured on death"
  local cause
  cause="$(cat "$(exit_json)" 2>/dev/null || true)"
  smoke_assert_contains "$cause" '"reason"' "exit-cause JSON carries a reason field"
  smoke_assert_contains "$cause" '"log_tail"' "exit-cause JSON carries a log_tail field"
  # The log_tail must be non-empty (the receiver logged at least a listening
  # line). A bare `"log_tail": []` would mean nothing was captured.
  smoke_assert_not_contains "$cause" '"log_tail": []' \
    "exit-cause log_tail is non-empty"
}

# --- Check 8 (run before crash-loop): systemd-defer = probe+alarm, no restart -
# With BRIDGE_A2A_RECEIVER_SYSTEMD_OWNER=1 the supervisor must DEFER: it logs
# the deferral and does NOT restart a dead receiver. Kill the receiver, sync
# with the override on, assert the deferral log AND that no new receiver came
# up.
check_systemd_defer() {
  local pid
  pid="$(receiver_pid_now)"
  if [[ -n "$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$(handoffd_pidfile)" 2>/dev/null || true

  local out
  out="$(BRIDGE_A2A_RECEIVER_SYSTEMD_OWNER=1 bash -c '
    rm -f "$1/handoff/receiver-supervise-tick.env" 2>/dev/null || true
    bash "$2/bridge-daemon.sh" sync 2>&1 || true
  ' _ "$BRIDGE_STATE_DIR" "$SMOKE_REPO_ROOT")"

  smoke_assert_contains "$out" "deferring restart to systemd" \
    "supervisor defers to systemd when agb-handoffd.service is the owner"
  # Port must remain unbound — the supervisor did NOT restart under systemd
  # ownership.
  local rc=0
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null || rc=$?
  smoke_assert_match "$rc" '^[1-9]' \
    "supervisor did NOT restart the receiver while deferring to systemd"
}

# --- Check 4: crash-loop cap + alarm + admin task + no launch past cap ---
# Point the config at an UNPROVABLE bind (tailnet-shaped, not a real local
# interface) with the tailscale CLI absent so bridge_a2a_receiver_start fails
# closed every time (bind_proof_failed). Run sync MAX+2 times. Assert the
# restart counter caps at MAX, the alarm is set, an a2a_receiver_crashloop
# audit row is present, an admin task was filed, and the receiver never came
# up (no `listening` past the cap).
check_crashloop_cap_and_alarm() {
  # Ensure no live receiver / stale pid first.
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  rm -f "$(handoffd_pidfile)" "$(supervise_state)" 2>/dev/null || true

  local crash_port
  crash_port="$(pick_free_port)"
  write_unprovable_config "$crash_port"

  # Register a minimal admin agent so the crash-loop admin task can be filed.
  # BRIDGE_AGENT_SESSION must be set for bridge_agent_exists() to recognize the
  # agent (it keys on BRIDGE_AGENT_SESSION[<agent>]); the task is filed with
  # --force so the stopped target (no live tmux) does not refuse the enqueue.
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="reviewer"
bridge_add_agent_id_if_missing "reviewer"
BRIDGE_AGENT_DESC["reviewer"]="1405 supervise admin"
BRIDGE_AGENT_ENGINE["reviewer"]="shell"
BRIDGE_AGENT_SESSION["reviewer"]="a2a-1405-reviewer-$$"
BRIDGE_AGENT_WORKDIR["reviewer"]="$BRIDGE_AGENT_HOME_ROOT/reviewer"
BRIDGE_AGENT_LAUNCH_CMD["reviewer"]="bash -lc 'echo reviewer'"
BRIDGE_AGENT_LOOP["reviewer"]=0
BRIDGE_AGENT_CONTINUE["reviewer"]=0
EOF
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/reviewer"

  local max="$BRIDGE_A2A_RECEIVER_MAX_RESTARTS"
  local syncs=$((max + 2))
  # tailscale CLI pointed at a nonexistent path => resolve_bind fails closed,
  # so bridge_a2a_receiver_start returns non-zero (bind_proof_failed) each tick.
  local i
  for (( i = 0; i < syncs; i++ )); do
    BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" run_sync >/dev/null
  done

  local state
  state="$(cat "$(supervise_state)" 2>/dev/null || true)"
  smoke_assert_contains "$state" "A2A_RECEIVER_ALARM=" "supervise.env carries an alarm field"
  # Alarm must be set (non-empty value). Pre-fix: no supervise.env at all.
  smoke_assert_match "$state" "A2A_RECEIVER_ALARM=('?)(crashloop|bind_proof_failed)" \
    "supervise.env alarm is set after the crash-loop cap"

  # Restart counter must cap at MAX (never exceed it despite syncs > MAX).
  local count
  count="$(printf '%s\n' "$state" | sed -n "s/^A2A_RECEIVER_RESTART_COUNT=//p" | tr -d "'" | head -1)"
  [[ "$count" =~ ^[0-9]+$ ]] || smoke_fail "could not parse restart count from supervise.env: $state"
  (( count <= max )) || smoke_fail "restart count ($count) exceeded the cap ($max)"
  (( count >= max )) || smoke_fail "restart count ($count) did not reach the cap ($max)"

  # The crash-loop audit row must be present.
  local audit
  audit="$(cat "$BRIDGE_AUDIT_LOG" 2>/dev/null || true)"
  smoke_assert_contains "$audit" "a2a_receiver_crashloop" \
    "a2a_receiver_crashloop audit row emitted at the cap"

  # An admin task must have been filed for the crash-loop alarm.
  local inbox
  inbox="$(bash "$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer 2>/dev/null || true)"
  smoke_assert_contains "$inbox" "crash-loop" \
    "crash-loop admin task filed to the admin agent"

  # The receiver must NEVER have come up (bind unprovable) — no live port.
  local rc=0
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$crash_port" 2>/dev/null || rc=$?
  smoke_assert_match "$rc" '^[1-9]' "receiver never bound (crash-loop config is unprovable)"
}

# --- Check 6: status alarm visible in agent-bridge status ---
# With the crash-loop alarm set (from check 4), the status dashboard must show
# the A2A receiver row + a DOWN/ALARM marker. Pre-fix: no row at all.
check_status_alarm_visible() {
  local out
  out="$(bash "$SMOKE_REPO_ROOT/bridge-status.sh" 2>/dev/null || true)"
  smoke_assert_contains "$out" "A2A receiver" "status dashboard renders the A2A receiver row"
  smoke_assert_match "$out" '(DOWN|ALARM)' "status dashboard marks the receiver DOWN/ALARM"
}

# --- Check 7: non-A2A install is silent (regression guard) ---
# No handoff.local.json -> sync exits 0, supervise tick is a no-op (no
# supervise.env / exit-cause writes), and the status dashboard renders NO A2A
# receiver row.
check_non_a2a_silent() {
  rm -f "$BRIDGE_HOME/handoff.local.json" \
    "$(supervise_state)" "$(exit_json)" \
    "$BRIDGE_STATE_DIR/handoff/receiver-supervise-tick.env" 2>/dev/null || true

  local out rc=0
  out="$(bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" sync 2>&1)" || rc=$?
  smoke_assert_eq "0" "$rc" "daemon sync exits 0 with no handoff config"
  smoke_assert_not_contains "$out" "a2a_receiver_supervise" \
    "no supervise tick output when handoff config absent"

  # No state files written by the supervise tick on a non-A2A install.
  [[ ! -f "$(supervise_state)" ]] || smoke_fail "supervise.env written on a non-A2A install"
  [[ ! -f "$(exit_json)" ]] || smoke_fail "receiver-exit.json written on a non-A2A install"

  local status_out
  status_out="$(bash "$SMOKE_REPO_ROOT/bridge-status.sh" 2>/dev/null || true)"
  smoke_assert_not_contains "$status_out" "A2A Receiver" \
    "status dashboard hides the A2A receiver section on a non-A2A install"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "1405-handoffd-supervision"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"

  smoke_run "healthz subcommand is green against a live receiver" check_healthz_green
  smoke_run "healthz detects a wedged (SIGSTOP) serve loop" check_healthz_detects_wedged
  smoke_run "auto-restart re-runs the fail-closed bind proof" check_auto_restart_reproves_bind
  smoke_run "exit-cause record captured on death" check_exit_cause_captured
  smoke_run "systemd-defer: probe+alarm only, no restart" check_systemd_defer
  smoke_run "crash-loop cap + alarm + admin task + no launch past cap" check_crashloop_cap_and_alarm
  smoke_run "status dashboard surfaces the receiver alarm" check_status_alarm_visible
  smoke_run "non-A2A install is silent (regression guard)" check_non_a2a_silent

  smoke_log "passed"
}

main "$@"
