#!/usr/bin/env bash
# scripts/smoke/1679-1680-a2a-receiver-supervisor-robustness.sh
#
# Issues #1679 + #1680: the A2A receiver supervisor
# (process_a2a_receiver_supervise_tick in bridge-daemon.sh) misclassifies
# ENVIRONMENTAL tailnet conditions on macOS as receiver FAULTS and floods the
# admin queue with false crash-loop / receiver-down tasks while the receiver is
# actually healthy (#1679) or down only because Tailscale is down (#1680).
#
# This smoke exercises the three robustness parts:
#   Part 1 (#1679): self-reachability discriminator. A healthz timeout where the
#     host cannot self-route to its OWN bind (self_unreachable) -> HOLD, no
#     restart, no restart_count increment, no crashloop task. A healthz timeout
#     where the host CAN self-reach (self_reachable) -> still treated as a
#     genuine wedge -> restart (the #1405 case preserved).
#   Part 2 (#1680): environmental bind_fail. A bind failure with the configured
#     tailnet IP ABSENT from every interface -> environmental re-probe, restart
#     budget NOT burned; when the IP returns -> auto-rebind (restart).
#   Part 3 (#1679+#1680): stateful incident note instead of a per-cycle flood —
#     ONE tracked env-incident task over a sustained outage, auto-cleared on
#     recovery; environmental conditions file NO crashloop task.
#   Regression: a genuine process death is still detected + restarted.
#
# Loopback harness (BRIDGE_A2A_ALLOW_TEST_BIND=1, free port) reused from
# 1405-handoffd-supervision.sh / a2a-cross-bridge.sh. The macOS self-route flap
# and a SYN-blackhole are not portably reproducible, so the self-reachability
# verdict is driven deterministically via BRIDGE_A2A_SELF_REACH_TEST_VERDICT
# (a read-only discriminator override that NEVER touches the bind/auth path),
# and the bind-IP presence via BRIDGE_A2A_IFACE_ADDRS (the existing interface-
# enumeration test override). EVERY assertion has teeth: pre-fix (no self-reach
# / bind-ip-present discriminator, no environmental hold) the relevant checks
# FAIL.

set -euo pipefail

SMOKE_NAME="1679-1680-a2a-receiver-supervisor-robustness"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  smoke_cleanup_temp_root
}
trap cleanup EXIT

A2A_PORT=""
A2A_SECRET="smoke-shared-secret-do-not-use-in-prod-0123456789"

export BRIDGE_A2A_ALLOW_TEST_BIND=1
export BRIDGE_A2A_RECEIVER_SUPERVISE_INTERVAL_SECONDS=1
export BRIDGE_A2A_RECEIVER_MAX_RESTARTS=3
export BRIDGE_A2A_RECEIVER_RESTART_WINDOW_SECONDS=600
export BRIDGE_A2A_RECEIVER_CRASHLOOP_ADMIN_COOLDOWN_SECONDS=1800
export BRIDGE_A2A_RECEIVER_HEALTHZ_TIMEOUT_SECONDS=2

pick_free_port() { python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" free-port; }
handoffd_pidfile() { printf '%s/handoff/handoffd.pid' "$BRIDGE_STATE_DIR"; }
handoffd_log() { printf '%s/a2a-handoffd.log' "$BRIDGE_LOG_DIR"; }
supervise_state() { printf '%s/handoff/receiver-supervise.env' "$BRIDGE_STATE_DIR"; }
env_incident_state() { printf '%s/handoff/receiver-env-incident.env' "$BRIDGE_STATE_DIR"; }

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

# Tailnet-shaped bind that is NOT a real local interface, with the tailscale CLI
# pointed at a nonexistent path so the receiver's fail-closed bind proof refuses
# every start (forces a bind-availability failure). Used for the #1680 path.
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

register_admin_reviewer() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="reviewer"
bridge_add_agent_id_if_missing "reviewer"
BRIDGE_AGENT_DESC["reviewer"]="1679/1680 supervise admin"
BRIDGE_AGENT_ENGINE["reviewer"]="shell"
BRIDGE_AGENT_SESSION["reviewer"]="a2a-1679-reviewer-$$"
BRIDGE_AGENT_WORKDIR["reviewer"]="$BRIDGE_AGENT_HOME_ROOT/reviewer"
BRIDGE_AGENT_LAUNCH_CMD["reviewer"]="bash -lc 'echo reviewer'"
BRIDGE_AGENT_LOOP["reviewer"]=0
BRIDGE_AGENT_CONTINUE["reviewer"]=0
EOF
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/reviewer"
}

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

receiver_pid_now() { cat "$(handoffd_pidfile)" 2>/dev/null || true; }

# run a single supervise sync with optional inline env (KEY=VAL ... ); the
# throttle is cleared first so the tick always runs.
run_sync_env() {
  clear_supervise_throttle
  env "$@" bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" sync 2>&1 || true
}

state_field() {
  local field="$1"
  sed -n "s/^A2A_RECEIVER_${field}=//p" "$(supervise_state)" 2>/dev/null \
    | tr -d "'" | head -1
}

reviewer_inbox() {
  bash "$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer 2>/dev/null || true
}

# Seed a genuine-shaped `bind_fail` terminal audit row into the receiver's
# a2a-handoff.jsonl — exactly the #1680 reproduction artifact (the issue's
# `state/handoff/receiver-exit.json` last_exit_event=bind_fail / Errno 49). The
# supervisor's read-only exit-cause helper mines this jsonl and reports
# exit_event=bind_fail, which is the precise signal the #1680 environmental gate
# keys on (the IP was bindable then vanished — distinct from a never-bindable
# misconfig that fails at resolve_bind with startup_fail). $1 = bind IP/addr.
# The row is plain JSON written with printf — NO heredoc-stdin to python
# (footgun #11). The detail string carries no special characters.
seed_bind_fail_exit() {
  local addr="$1" port="${2:-8787}" ts
  ts="$(date +%s)"
  mkdir -p "$BRIDGE_LOG_DIR"
  printf '{"ts": %s, "component": "a2a-handoffd", "event": "bind_fail", "address": "%s", "port": %s, "detail": "[Errno 49] Cannot assign requested address", "phase": "bind"}\n' \
    "$ts" "$addr" "$port" >>"$BRIDGE_LOG_DIR/a2a-handoff.jsonl"
}

count_env_incident_tasks() {
  # Count OPEN env-incident notes (self-unreachable / tailnet IP absent).
  reviewer_inbox | grep -ciE 'self-unreachable|tailnet IP absent|environmental' || true
}

# -------------------------------------------------------------------------
# Case (a) — #1679: healthz timeout + self_unreachable => HOLD, no restart.
# -------------------------------------------------------------------------
check_self_unreachable_holds() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  rm -f "$(supervise_state)" "$(env_incident_state)" 2>/dev/null || true

  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle
  local pid
  pid="$(receiver_pid_now)"
  [[ -n "$pid" ]] || smoke_fail "no receiver pid for self-unreachable test"

  # The receiver stays RUNNING (process gate passes). We force the healthz
  # reason to healthz_timeout AND the self-reach discriminator to
  # self_unreachable — exactly the #1679 self-route flap (healthy receiver, host
  # can't reach its own IP). The supervisor must HOLD (not restart, not count a
  # death). Two consecutive unhealthy probes confirm before the discriminator
  # runs, so several syncs are needed (1st tolerates, 2nd confirms+discriminates).
  local i
  for (( i = 0; i < 4; i++ )); do
    run_sync_env \
      BRIDGE_A2A_HEALTHZ_TEST_VERDICT=healthz_timeout \
      BRIDGE_A2A_SELF_REACH_TEST_VERDICT=self_unreachable >/dev/null
  done

  local reason restart_count
  reason="$(state_field LAST_REASON)"
  restart_count="$(state_field RESTART_COUNT)"
  smoke_assert_eq "healthz_unreachable_self" "$reason" \
    "self-unreachable healthz timeout recorded as healthz_unreachable_self (HOLD)"
  smoke_assert_eq "0" "${restart_count:-0}" \
    "restart_count NOT incremented on a self-route flap (#1679)"

  # The held process must still be the SAME pid (never restarted).
  local pid_after
  pid_after="$(receiver_pid_now)"
  smoke_assert_eq "$pid" "$pid_after" "receiver pid unchanged — held, not restarted"

  # NO crashloop task; at most ONE env-incident note, clearly labeled.
  local inbox
  inbox="$(reviewer_inbox)"
  smoke_assert_not_contains "$inbox" "crash-loop — auto-restart stopped" \
    "no crashloop admin task filed for a self-route flap (#1679)"
  printf '%s' "$inbox" | grep -qiE 'self-unreachable|host/tailnet condition' \
    || smoke_fail "expected a labeled self-unreachable env-incident note: $inbox"

  # A self-unreachable audit row must be present.
  grep -q 'a2a_receiver_self_unreachable' "$BRIDGE_AUDIT_LOG" 2>/dev/null \
    || smoke_fail "no a2a_receiver_self_unreachable audit emitted"

  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
}

# -------------------------------------------------------------------------
# Case (b) — #1679/#1405: healthz timeout + self_reachable => genuine wedge
# => restart path preserved (NOT held).
# -------------------------------------------------------------------------
check_self_reachable_restarts() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  rm -f "$(supervise_state)" "$(env_incident_state)" 2>/dev/null || true

  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle
  local pid
  pid="$(receiver_pid_now)"
  [[ -n "$pid" ]] || smoke_fail "no receiver pid for self-reachable test"

  # Receiver stays running; force healthz_timeout + self_reachable so the
  # supervisor classifies a GENUINE wedge (host CAN reach its own IP) and goes
  # down the restart path (does NOT hold). The #1405 wedge-detection is
  # preserved.
  local i
  for (( i = 0; i < 4; i++ )); do
    run_sync_env \
      BRIDGE_A2A_HEALTHZ_TEST_VERDICT=healthz_timeout \
      BRIDGE_A2A_SELF_REACH_TEST_VERDICT=self_reachable >/dev/null
  done

  local reason
  reason="$(state_field LAST_REASON)"
  # When self-reachable, the supervisor must NOT record the hold reason — it
  # treats it as a genuine wedge (restart attempt / bind-proof path).
  [[ "$reason" != "healthz_unreachable_self" ]] \
    || smoke_fail "self-reachable wedge was wrongly held (reason=$reason); the #1405 restart path must be preserved"
  # No env-incident note for a genuine wedge.
  [[ ! -f "$(env_incident_state)" ]] \
    || smoke_fail "env-incident opened for a genuine (self-reachable) wedge"

  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
}

# -------------------------------------------------------------------------
# Case (c) — #1680: bind_fail with tailnet IP ABSENT => environmental,
# restart budget NOT burned; re-probe loop; auto-rebind when IP returns.
# -------------------------------------------------------------------------
check_bind_ip_absent_environmental() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  rm -f "$(handoffd_pidfile)" "$(supervise_state)" "$(env_incident_state)" \
    "$BRIDGE_LOG_DIR/a2a-handoff.jsonl" 2>/dev/null || true

  local crash_port
  crash_port="$(pick_free_port)"
  write_unprovable_config "$crash_port"

  # Seed the #1680 incident artifact: a `bind_fail` (Errno 49) terminal row, as
  # the receiver writes when the tailnet IP it WAS bound to leaves the interface
  # (resolve_bind passed on the cached IP, the socket bind then failed). This is
  # what makes the supervisor's exit-cause helper report exit_event=bind_fail —
  # the precise #1680 signal (distinct from a never-bindable misconfig).
  seed_bind_fail_exit "100.64.0.10" "$crash_port"

  # The configured bind IP (100.64.0.10) is ABSENT from the simulated interface
  # set, the tailscale CLI is absent, and the receiver is down. Many syncs must
  # NOT burn the restart budget or open the circuit breaker — it is an
  # environmental hold that re-probes.
  local i
  for (( i = 0; i < 10; i++ )); do
    seed_bind_fail_exit "100.64.0.10" "$crash_port"
    run_sync_env \
      BRIDGE_A2A_IFACE_ADDRS="10.9.9.9 192.168.50.50" \
      BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" \
      BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS=1 \
      BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3 \
      BRIDGE_A2A_RECEIVER_ENV_REPROBE_SECONDS=1 \
      >/dev/null
  done

  local alarm restart_count consec_transient
  alarm="$(state_field ALARM)"
  restart_count="$(state_field RESTART_COUNT)"
  consec_transient="$(state_field CONSEC_TRANSIENT)"
  smoke_assert_eq "env_bind_ip_absent" "$alarm" \
    "bind_fail with absent tailnet IP held as environmental (alarm=env_bind_ip_absent)"
  smoke_assert_eq "0" "${restart_count:-0}" \
    "restart budget NOT burned by an absent tailnet IP (#1680)"
  smoke_assert_eq "0" "${consec_transient:-0}" \
    "circuit-breaker counter NOT advanced by an absent tailnet IP (#1680)"

  # The breaker must NOT have opened (no permanent stop).
  grep -q 'a2a_receiver_circuit_open' "$BRIDGE_AUDIT_LOG" 2>/dev/null \
    && smoke_fail "circuit OPENED on an absent tailnet IP — must re-probe, not permanently stop"
  grep -q 'a2a_receiver_bind_ip_absent' "$BRIDGE_AUDIT_LOG" 2>/dev/null \
    || smoke_fail "no a2a_receiver_bind_ip_absent audit emitted"

  # Auto-rebind: bring the IP "back" (interface set now includes the bind IP).
  # The supervisor must clear the env incident and ATTEMPT a restart (proceed
  # to the restart path). We assert the auto-rebind log + incident clear; the
  # bind itself still cannot succeed in the hermetic harness (no real tailnet),
  # so we only assert the supervisor LEFT the environmental hold.
  seed_bind_fail_exit "100.64.0.10" "$crash_port"
  local rebind_out
  rebind_out="$(run_sync_env \
    BRIDGE_A2A_IFACE_ADDRS="10.9.9.9 100.64.0.10" \
    BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" \
    BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS=1 \
    BRIDGE_A2A_RECEIVER_ENV_REPROBE_SECONDS=1)"
  smoke_assert_contains "$rebind_out" "auto-rebind" \
    "supervisor logged auto-rebind when the bind IP returned (#1680)"
  local alarm_after
  alarm_after="$(state_field ALARM)"
  [[ "$alarm_after" != "env_bind_ip_absent" ]] \
    || smoke_fail "supervisor stayed in the environmental hold after the bind IP returned (no auto-rebind)"
  # The env incident must be CLEARED on the rebind.
  [[ ! -f "$(env_incident_state)" ]] \
    || smoke_fail "env-incident not cleared after the bind IP returned (auto-rebind should close it)"
}

# -------------------------------------------------------------------------
# Case (d) — alert-flood collapse: a sustained environmental outage files
# ONE stateful env-incident task, not N.
# -------------------------------------------------------------------------
check_alert_flood_collapse() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  rm -f "$(handoffd_pidfile)" "$(supervise_state)" "$(env_incident_state)" \
    "$BRIDGE_LOG_DIR/a2a-handoff.jsonl" 2>/dev/null || true
  # Drain any prior reviewer inbox state so the count is for THIS outage only.
  # (Fresh tasks.db not needed; we count by title and compare to a single one.)

  local crash_port
  crash_port="$(pick_free_port)"
  write_unprovable_config "$crash_port"

  local before
  before="$(count_env_incident_tasks)"

  # 12 supervise cycles over a sustained absent-IP outage (each preceded by the
  # #1680 bind_fail incident artifact). With the cooldown at its 1800s default,
  # the env-incident note may file AT MOST once — never one per cycle.
  local i
  for (( i = 0; i < 12; i++ )); do
    seed_bind_fail_exit "100.64.0.10" "$crash_port"
    run_sync_env \
      BRIDGE_A2A_IFACE_ADDRS="10.9.9.9 192.168.50.50" \
      BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" \
      BRIDGE_A2A_RECEIVER_ENV_REPROBE_SECONDS=1 \
      >/dev/null
  done

  local after delta
  after="$(count_env_incident_tasks)"
  delta=$(( after - before ))
  (( delta >= 0 )) || delta=0
  (( delta <= 1 )) \
    || smoke_fail "alert flood: $delta env-incident tasks filed over a sustained outage (expected <=1)"

  # Exactly ONE open incident is tracked in state, regardless of cycle count.
  smoke_assert_file_exists "$(env_incident_state)" \
    "a single stateful env-incident is tracked across the outage"

  # And NO crashloop task at all (environmental != fault).
  local inbox
  inbox="$(reviewer_inbox)"
  smoke_assert_not_contains "$inbox" "crash-loop — auto-restart stopped" \
    "no crashloop task filed for a sustained environmental outage (#1680)"
}

# -------------------------------------------------------------------------
# Case (e) — regression: a GENUINE process death is still DETECTED and the
# supervisor still ATTEMPTS a restart. The environmental gates (#1679/#1680)
# must not suppress real-fault handling. The supervised restart correctly
# SCRUBS the inherited loopback test-bind (the #1414 security guard), so in this
# hermetic loopback harness the restart attempt fails the production bind proof
# (bind_proof_failed) rather than relaunching — which is the right behavior.
# The regression assertion is therefore: the death was detected and a restart
# was ATTEMPTED + recorded (NOT held as environmental), with the iface set
# containing the bind IP so the #1680 gate cannot misclassify it.
# -------------------------------------------------------------------------
check_genuine_death_still_handled() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  rm -f "$(supervise_state)" "$(env_incident_state)" 2>/dev/null || true

  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle
  local old_pid
  old_pid="$(receiver_pid_now)"
  [[ -n "$old_pid" ]] || smoke_fail "no receiver pid for genuine-death test"

  # Kill the receiver outright (process_gone — NOT a healthz timeout, NOT a
  # bind_fail). The supervisor must detect the death via the process gate.
  kill -9 "$old_pid" 2>/dev/null || true
  wait "$old_pid" 2>/dev/null || true
  rm -f "$(handoffd_pidfile)" 2>/dev/null || true
  local waited=0
  while python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null; do
    sleep 0.1; waited=$((waited + 1)); (( waited > 50 )) && break
  done

  # Mark the audit boundary so we inspect only THIS death's rows.
  local audit_before
  audit_before="$(wc -l < "$BRIDGE_AUDIT_LOG" 2>/dev/null || printf '0')"
  # The bind IP (127.0.0.1, loopback) is present on the interface, so the #1680
  # gate cannot mistake this death for an absent-tailnet-IP environmental case.
  run_sync_env BRIDGE_A2A_IFACE_ADDRS="127.0.0.1 10.0.0.5" >/dev/null

  # Death detected: an a2a_receiver_died audit row must appear for this sync.
  local fresh_audit
  fresh_audit="$(tail -n +"$((audit_before + 1))" "$BRIDGE_AUDIT_LOG" 2>/dev/null || true)"
  printf '%s' "$fresh_audit" | grep -q 'a2a_receiver_died' \
    || smoke_fail "genuine process death was NOT detected (no a2a_receiver_died audit)"

  # NOT held as environmental: no env-incident, alarm is not the env hold.
  [[ ! -f "$(env_incident_state)" ]] \
    || smoke_fail "genuine process death was wrongly held as environmental"
  local alarm reason
  alarm="$(state_field ALARM)"
  reason="$(state_field LAST_REASON)"
  [[ "$alarm" != "env_bind_ip_absent" ]] \
    || smoke_fail "genuine process death wrongly classified env_bind_ip_absent"
  [[ "$reason" != "healthz_unreachable_self" && "$reason" != "bind_ip_absent" ]] \
    || smoke_fail "genuine process death wrongly held (reason=$reason)"

  # A restart WAS attempted (the supervisor did not silently hold a real death).
  # In the loopback harness the production bind proof refuses the scrubbed
  # restart -> bind_proof_failed, which proves the attempt happened.
  smoke_assert_eq "bind_proof_failed" "$reason" \
    "genuine death -> restart ATTEMPTED (recorded bind_proof_failed under the production bind contract)"

  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "1679-1680-a2a-receiver-supervisor-robustness"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  register_admin_reviewer

  smoke_run "(a) #1679 self-unreachable healthz timeout -> HOLD, no restart, no crashloop task" check_self_unreachable_holds
  smoke_run "(b) #1405 self-reachable healthz timeout -> genuine wedge restart preserved" check_self_reachable_restarts
  smoke_run "(c) #1680 bind_fail + absent tailnet IP -> environmental, budget preserved, auto-rebind" check_bind_ip_absent_environmental
  smoke_run "(d) alert flood collapse -> ONE stateful env-incident over a sustained outage" check_alert_flood_collapse
  smoke_run "(e) regression: genuine process death still detected + restarted" check_genuine_death_still_handled

  smoke_log "passed"
}

main "$@"
