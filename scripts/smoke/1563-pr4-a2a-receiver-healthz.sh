#!/usr/bin/env bash
# scripts/smoke/1563-pr4-a2a-receiver-healthz.sh — A2A receiver supervision
# BACKOFF + CIRCUIT BREAKER smoke (#1563 PR-4).
#
# Problem (#1563): when the tailnet bind address is transiently unavailable
# (tailnet not yet up / IP drift after a re-login) the A2A receiver
# (bridge-handoffd.py) fails its fail-closed preflight, EXITS, gets respawned
# immediately, and fails again — a ~9-minute crash-loop with NO backoff.
#
# PR-4 hardens the daemon supervision (process_a2a_receiver_supervise_tick in
# bridge-daemon.sh, the policy helpers in lib/bridge-a2a.sh, the exit-cause
# classifier in lib/daemon-helpers/a2a-receiver-exit-cause.py, the phase tags
# in bridge-handoffd.py): a TRANSIENT bind failure (config+secret VALID, the
# error is network/bind availability) now backs off exponentially and, after N
# consecutive failures for the same (config-fingerprint, error_class) key,
# OPENS a circuit breaker (stop respawning + escalate ONCE per cooldown). A
# real AUTH/CONFIG error (bad/missing secret, malformed config) is NEVER routed
# through the transient-retry path — it is HELD immediately. A successful bind
# RESETS the breaker. The escalation task-create failure is AUDITED
# (a2a_receiver_escalation_task_create_failed), never swallowed.
#
# CRITICAL: this PR changes the SUPERVISION/restart policy ONLY — it does NOT
# touch what the receiver ACCEPTS. The fail-closed tailnet bind proof, HMAC
# verification, remote_addr check, allowlist, and dedupe are UNCHANGED. Check
# (d) below is the teeth that pin that: the receiver still refuses
# loopback/wildcard/non-tailnet binds and still 401s a bad HMAC / 403s an
# unknown peer.
#
# Asserts:
#   1. policy helpers (unit): backoff is exponential+capped, the breaker opens
#      at the threshold, and bridge_a2a_supervise_decision returns the right
#      word for transient/auth_config/unknown.
#   (a) transient bind-unavailable [config+secret VALID] -> backoff (a `wait`
#       tick with NO immediate respawn) -> after N -> circuit OPEN + ONE
#       escalation audit + ONE admin task; NO thrash.
#   (b) auth/config error (empty-secret peer) -> classified auth_config -> HELD
#       (a2a_receiver_auth_config_hold) -> NOT routed into the backoff thrash.
#   (c) a successful bind RESETS the breaker (consec_transient -> 0).
#   (d) fail-closed INTACT: the receiver still refuses the unprovable
#       tailnet/loopback bind AND still 401s a bad HMAC / 403s an unknown peer
#       — the healthz change did NOT loosen the boundary.
#   (e) escalation task-create FAILURE -> a2a_receiver_escalation_task_create_
#       failed audit + retry state (last_admin_task_ts NOT advanced).
#
# Loopback / test-bind harness (BRIDGE_A2A_ALLOW_TEST_BIND=1, free port) +
# stubbed `tailscale` (absent -> resolve_bind fails closed) mirror
# 1405-handoffd-supervision.sh and a2a-cross-bridge.sh. EVERY assertion has
# teeth: pre-PR-4 (no classification, no backoff/breaker, no shared escalate
# helper) the relevant checks FAIL.

set -euo pipefail

SMOKE_NAME="1563-pr4-a2a-receiver-healthz"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HANDOFFD_PID=""

cleanup() {
  if [[ -n "$HANDOFFD_PID" ]]; then
    kill -CONT "$HANDOFFD_PID" >/dev/null 2>&1 || true
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  smoke_cleanup_temp_root
}
trap cleanup EXIT

A2A_PORT=""
A2A_SECRET="smoke-shared-secret-do-not-use-in-prod-0123456789"

# Receiver test-bind escape hatch + a fast supervise cadence. We delete the
# tick-throttle file before each sync (clear_supervise_throttle) so the cadence
# gate never blocks a test sync, but a low interval keeps the window short too.
export BRIDGE_A2A_ALLOW_TEST_BIND=1
export BRIDGE_A2A_RECEIVER_SUPERVISE_INTERVAL_SECONDS=1
# Generous legacy crash-loop cap so the #1563 backoff/breaker — NOT the legacy
# restart_count cap — is what latches in the transient scenario (we want to
# prove the NEW behavior, so keep max_restarts above the breaker threshold).
export BRIDGE_A2A_RECEIVER_MAX_RESTARTS=20
export BRIDGE_A2A_RECEIVER_RESTART_WINDOW_SECONDS=600
export BRIDGE_A2A_RECEIVER_CRASHLOOP_ADMIN_COOLDOWN_SECONDS=1800
export BRIDGE_A2A_RECEIVER_HEALTHZ_TIMEOUT_SECONDS=2
# #1563 backoff/breaker knobs. The per-check functions OVERRIDE the base/cap
# to suit the two distinct things they prove:
#   - the backoff/no-thrash check sets a LARGE base so the second consecutive
#     transient failure lands a `wait` tick (backoff window not yet elapsed) —
#     proving NO immediate respawn.
#   - the circuit-open check sets a TINY base so `retry` fires every fast test
#     tick and the transient counter climbs to the (low) open threshold.
# The default open threshold is low so the circuit opens in a few syncs.
export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3

# A stub `tailscale` that is ABSENT (nonexistent path): resolve_bind cannot
# prove the bind is in the local tailnet set and fails closed -> transient
# bind-availability error. This is the IP-drift / tailnet-down condition.
NO_TAILSCALE=""

pick_free_port() {
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" free-port
}

handoffd_pidfile() { printf '%s/handoff/handoffd.pid' "$BRIDGE_STATE_DIR"; }
handoffd_log()     { printf '%s/a2a-handoffd.log' "$BRIDGE_LOG_DIR"; }
supervise_state()  { printf '%s/handoff/receiver-supervise.env' "$BRIDGE_STATE_DIR"; }
exit_json()        { printf '%s/handoff/receiver-exit.json' "$BRIDGE_STATE_DIR"; }
config_path()      { printf '%s/handoff.local.json' "$BRIDGE_HOME"; }

# Clear the supervise cadence throttle so the NEXT `bridge-daemon.sh sync`
# always runs the supervise tick (wall-clock would otherwise gate it).
clear_supervise_throttle() {
  rm -f "$BRIDGE_STATE_DIR/handoff/receiver-supervise-tick.env" 2>/dev/null || true
}

# Run one supervise tick. The tailscale CLI is pointed at a nonexistent path so
# resolve_bind fails closed (no CIDR fallback) — the transient bind-unavailable
# condition — for the duration of THIS sync only.
run_sync_no_tailnet() {
  clear_supervise_throttle
  BRIDGE_A2A_TAILSCALE_CLI="$NO_TAILSCALE" \
    bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" sync 2>&1 || true
}

run_sync() {
  clear_supervise_throttle
  bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" sync 2>&1 || true
}

# A valid loopback config: bind 127.0.0.1 under BRIDGE_A2A_ALLOW_TEST_BIND so a
# real receiver can come up (used for the recovery + fail-closed-teeth checks).
write_loopback_config() {
  local port="$1"
  mkdir -p "$BRIDGE_HOME"
  {
    printf '{\n'
    printf '  "bridge_id": "bridge-b",\n'
    printf '  "listen": { "address": "127.0.0.1", "port": %s, "enqueue_path": "/enqueue" },\n' "$port"
    printf '  "timestamp_skew_seconds": 300,\n'
    printf '  "peers": [\n'
    printf '    {\n'
    printf '      "id": "bridge-a",\n'
    printf '      "address": "127.0.0.1",\n'
    printf '      "port": %s,\n' "$port"
    printf '      "secret": "%s",\n' "$A2A_SECRET"
    printf '      "inbound_allowlist": ["reviewer"],\n'
    printf '      "caps": { "max_body_bytes": 262144 }\n'
    printf '    }\n'
    printf '  ]\n'
    printf '}\n'
  } >"$(config_path)"
  chmod 0600 "$(config_path)"
}

# An UNPROVABLE bind: a tailnet-shaped (100.64.0.0/10) address that is NOT a
# real local interface, with the tailscale CLI absent so resolve_bind fails
# closed (transient bind-availability error, config+secret VALID). This is the
# transient scenario — preflight fails at the BIND phase.
write_unprovable_config() {
  local port="$1"
  mkdir -p "$BRIDGE_HOME"
  {
    printf '{\n'
    printf '  "bridge_id": "bridge-b",\n'
    printf '  "listen": { "address": "100.64.0.10", "port": %s, "enqueue_path": "/enqueue" },\n' "$port"
    printf '  "timestamp_skew_seconds": 300,\n'
    printf '  "peers": [\n'
    printf '    {\n'
    printf '      "id": "bridge-a",\n'
    printf '      "address": "127.0.0.1",\n'
    printf '      "port": %s,\n' "$port"
    printf '      "secret": "%s",\n' "$A2A_SECRET"
    printf '      "inbound_allowlist": ["reviewer"]\n'
    printf '    }\n'
    printf '  ]\n'
    printf '}\n'
  } >"$(config_path)"
  chmod 0600 "$(config_path)"
}

# A config that fails at the CONFIG phase: a peer with an EMPTY secret. The
# fail-closed preflight (validate_config_peer_secrets) refuses to start with
# code=peer_no_secret, phase=config -> classified auth_config (NON-transient).
# Note: BRIDGE_A2A_ALLOW_TEST_BIND alone does NOT bypass the secret gate (only
# the paired DEV_INSECURE_BIND does, which we never set), so this stays a
# genuine auth/config failure.
write_empty_secret_config() {
  local port="$1"
  mkdir -p "$BRIDGE_HOME"
  {
    printf '{\n'
    printf '  "bridge_id": "bridge-b",\n'
    printf '  "listen": { "address": "127.0.0.1", "port": %s, "enqueue_path": "/enqueue" },\n' "$port"
    printf '  "timestamp_skew_seconds": 300,\n'
    printf '  "peers": [\n'
    printf '    {\n'
    printf '      "id": "bridge-a",\n'
    printf '      "address": "127.0.0.1",\n'
    printf '      "port": %s,\n' "$port"
    printf '      "secret": "",\n'
    printf '      "inbound_allowlist": ["reviewer"]\n'
    printf '    }\n'
    printf '  ]\n'
    printf '}\n'
  } >"$(config_path)"
  chmod 0600 "$(config_path)"
}

# A MALFORMED config (invalid JSON). load_config() raises config_parse at the
# CONFIG phase — BEFORE any bind/secret check. This is the path codex's review
# flagged: pre-fix, cmd_preflight did NOT audit load_config failures with
# phase=config, so the exit-cause classifier saw no terminal row for this
# failure and fell back to `unknown` — or, with a STALE bind-phase row still in
# the jsonl, mis-classified the config error as `transient`. The fix audits
# load_config A2AErrors as phase=config so it is reliably held as auth_config.
write_malformed_config() {
  # Truncated JSON object — json.load raises -> config_parse.
  printf '{ "bridge_id": "bridge-b", "listen": { "address":' >"$(config_path)"
  chmod 0600 "$(config_path)"
}

# Register a minimal admin agent so the escalation admin task can be filed.
# BRIDGE_AGENT_SESSION must be set for bridge_agent_exists() to recognize it;
# the task is filed with --force so the stopped target still gets enqueued.
register_admin_agent() {
  {
    printf 'BRIDGE_ADMIN_AGENT_ID="reviewer"\n'
    printf 'bridge_add_agent_id_if_missing "reviewer"\n'
    printf 'BRIDGE_AGENT_DESC["reviewer"]="1563 pr4 supervise admin"\n'
    printf 'BRIDGE_AGENT_ENGINE["reviewer"]="shell"\n'
    printf 'BRIDGE_AGENT_SESSION["reviewer"]="a2a-1563-reviewer-%s"\n' "$$"
    printf 'BRIDGE_AGENT_WORKDIR["reviewer"]="%s/reviewer"\n' "$BRIDGE_AGENT_HOME_ROOT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["reviewer"]="bash -lc '\''echo reviewer'\''"\n'
    printf 'BRIDGE_AGENT_LOOP["reviewer"]=0\n'
    printf 'BRIDGE_AGENT_CONTINUE["reviewer"]=0\n'
  } >"$BRIDGE_ROSTER_LOCAL_FILE"
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

# Read a field from supervise.env (value may be `printf '%q'`-quoted -> strip).
supervise_field() {
  local key="$1" state
  state="$(cat "$(supervise_state)" 2>/dev/null || true)"
  printf '%s\n' "$state" | sed -n "s/^${key}=//p" | tr -d "'" | head -1
}

audit_log_text() { cat "$BRIDGE_AUDIT_LOG" 2>/dev/null || true; }

# Reset BOTH the controller audit log AND the receiver's own structured jsonl
# between scenarios. The exit-cause classifier mines the LAST terminal event
# from a2a-handoff.jsonl; without clearing it a later scenario would inherit an
# earlier scenario's terminal row (e.g. a config-phase peer_no_secret) and be
# misclassified. Also clear the supervise state + exit-cause + tick throttle so
# each scenario starts from a clean breaker.
reset_scenario_state() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  rm -f "$(handoffd_pidfile)" "$(supervise_state)" "$(exit_json)" \
    "$BRIDGE_STATE_DIR/handoff/receiver-supervise-tick.env" \
    "$BRIDGE_LOG_DIR/a2a-handoff.jsonl" "$BRIDGE_LOG_DIR/a2a-handoffd.log" \
    2>/dev/null || true
  : >"$BRIDGE_AUDIT_LOG" 2>/dev/null || true
}

# --- Check 1: policy helpers (unit) — backoff + breaker + decision word ------
# Source lib/bridge-a2a.sh in a subshell and exercise the pure decision helpers
# directly. Pre-PR-4 these functions do not exist (the source/call FAILS), so
# every assertion has teeth.
check_policy_helpers() {
  local out
  out="$(
    set +e
    # The backoff/threshold env knobs are exported above; unset them here so we
    # test the documented DEFAULTS, then a compressed schedule explicitly.
    unset BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS \
          BRIDGE_A2A_RECEIVER_BACKOFF_CAP_SECONDS \
          BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD
    # shellcheck source=lib/bridge-a2a.sh
    source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh" 2>/dev/null
    printf 'b1=%s\n' "$(bridge_a2a_backoff_seconds 1)"
    printf 'b2=%s\n' "$(bridge_a2a_backoff_seconds 2)"
    printf 'b3=%s\n' "$(bridge_a2a_backoff_seconds 3)"
    # Cap at 900 by default; a huge n must clamp, never overflow/spin.
    printf 'bcap=%s\n' "$(bridge_a2a_backoff_seconds 99)"
    # breaker opens at the default threshold (5).
    if bridge_a2a_breaker_should_open 4; then printf 'open4=yes\n'; else printf 'open4=no\n'; fi
    if bridge_a2a_breaker_should_open 5; then printf 'open5=yes\n'; else printf 'open5=no\n'; fi
    # decision words. auth_config -> hold (never retry). unknown -> retry
    # (legacy bounded restart). transient w/ 0 prior -> retry (first attempt).
    printf 'd_auth=%s\n' "$(bridge_a2a_supervise_decision auth_config 0 0 0)"
    printf 'd_unknown=%s\n' "$(bridge_a2a_supervise_decision unknown 9 0 100)"
    printf 'd_first=%s\n' "$(bridge_a2a_supervise_decision transient 0 0 100)"
    # transient w/ 1 prior, last_attempt very recent -> wait (inside backoff).
    printf 'd_wait=%s\n' "$(bridge_a2a_supervise_decision transient 1 100 100)"
    # transient w/ 1 prior, last_attempt long ago -> retry (backoff elapsed).
    printf 'd_retry=%s\n' "$(bridge_a2a_supervise_decision transient 1 0 100000)"
    # transient at/over threshold -> open.
    printf 'd_open=%s\n' "$(bridge_a2a_supervise_decision transient 5 0 100000)"
  )"
  smoke_assert_contains "$out" "b1=30" "backoff(1) = base (30s default)"
  smoke_assert_contains "$out" "b2=60" "backoff(2) = base*2 (60s)"
  smoke_assert_contains "$out" "b3=120" "backoff(3) = base*4 (120s)"
  smoke_assert_contains "$out" "bcap=900" "backoff clamps to the 900s cap (no overflow)"
  smoke_assert_contains "$out" "open4=no" "breaker stays CLOSED below threshold (4<5)"
  smoke_assert_contains "$out" "open5=yes" "breaker OPENS at threshold (5)"
  smoke_assert_contains "$out" "d_auth=hold" "auth_config -> hold (never retried into a thrash)"
  smoke_assert_contains "$out" "d_unknown=retry" "unknown -> retry (legacy bounded restart)"
  smoke_assert_contains "$out" "d_first=retry" "transient first failure -> retry"
  smoke_assert_contains "$out" "d_wait=wait" "transient inside backoff window -> wait (no respawn)"
  smoke_assert_contains "$out" "d_retry=retry" "transient after backoff elapsed -> retry"
  smoke_assert_contains "$out" "d_open=open" "transient at threshold -> open"
}

# --- Check 2: exit-cause classifier tags transient vs auth_config ------------
# Drive the standalone helper directly with a synthesized jsonl audit row for
# each phase and assert the error_class it emits. Pre-PR-4 the helper has no
# error_class field at all (the grep FAILS).
check_exit_cause_classifier() {
  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/1563-classify.XXXXXX")"
  # transient: a bind-phase tailscale_unavailable row.
  printf '%s\n' '{"event":"startup_fail","code":"tailscale_unavailable","phase":"bind","detail":"tailnet down"}' >"$tmpdir/transient.jsonl"
  # auth_config: a config-phase peer_no_secret row.
  printf '%s\n' '{"event":"startup_fail","code":"peer_no_secret","phase":"config","detail":"no secret"}' >"$tmpdir/auth.jsonl"
  : >"$tmpdir/empty.log"

  local out_t out_a
  out_t="$(python3 "$SCRIPT_DIR/../../lib/daemon-helpers/a2a-receiver-exit-cause.py" \
    "$tmpdir/out-t.json" "$tmpdir/empty.log" "$tmpdir/transient.jsonl" \
    bind_proof_failed 123 1000 20 2>/dev/null || true)"
  out_a="$(python3 "$SCRIPT_DIR/../../lib/daemon-helpers/a2a-receiver-exit-cause.py" \
    "$tmpdir/out-a.json" "$tmpdir/empty.log" "$tmpdir/auth.jsonl" \
    startup_fail 123 1000 20 2>/dev/null || true)"

  # The TSV summary's 3rd field is error_class.
  smoke_assert_match "$out_t" 'transient' "bind-phase tailscale_unavailable -> error_class=transient"
  smoke_assert_match "$out_a" 'auth_config' "config-phase peer_no_secret -> error_class=auth_config"
  smoke_assert_contains "$(cat "$tmpdir/out-t.json" 2>/dev/null)" '"error_class": "transient"' \
    "exit-cause JSON carries error_class=transient for the bind-phase row"
  smoke_assert_contains "$(cat "$tmpdir/out-a.json" 2>/dev/null)" '"error_class": "auth_config"' \
    "exit-cause JSON carries error_class=auth_config for the config-phase row"
  rm -rf "$tmpdir" 2>/dev/null || true
}

# --- Check (a1): transient bind failure BACKS OFF (no immediate respawn) -----
# Unprovable tailnet bind + absent tailscale CLI, with a LARGE backoff base so
# a transient failure lands a `wait` tick (backoff window not yet elapsed)
# instead of a respawn. The supervisor needs a couple of ticks to first OBSERVE
# the failure as transient (the first down tick has no prior startup_fail audit
# yet, so it classifies `unknown` and retries; the breaker key then re-seeds
# when the class settles to transient), after which a tick whose backoff window
# has not elapsed BACKS OFF: alarm=bind_backoff, a a2a_receiver_bind_backoff
# audit, and CRUCIALLY the restart counter does NOT advance (no respawn). That
# is the anti-thrash. Pre-PR-4 there is no backoff at all — every tick respawns
# immediately, so the bind_backoff alarm/audit never appears.
check_transient_backs_off() {
  reset_scenario_state

  A2A_PORT="$(pick_free_port)"
  write_unprovable_config "$A2A_PORT"

  # Large base => the backoff window (>=1h) far exceeds the test inter-tick gap,
  # so once a transient failure is recorded the NEXT tick MUST `wait`. High
  # threshold so the breaker does not open first (we isolate the backoff here).
  export BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS=3600
  export BRIDGE_A2A_RECEIVER_BACKOFF_CAP_SECONDS=7200
  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=99

  # Drive ticks until a `wait` (bind_backoff) tick lands, capturing the
  # restart counter from the tick JUST BEFORE the backoff so we can prove the
  # backoff tick did NOT respawn (counter held).
  local i alarm prev_rc="" rc_at_backoff="" saw_backoff=0
  for (( i = 0; i < 6; i++ )); do
    local rc_before
    rc_before="$(supervise_field A2A_RECEIVER_RESTART_COUNT)"
    [[ "$rc_before" =~ ^[0-9]+$ ]] || rc_before=0
    run_sync_no_tailnet >/dev/null
    alarm="$(supervise_field A2A_RECEIVER_ALARM)"
    if [[ "$alarm" == "bind_backoff" ]]; then
      prev_rc="$rc_before"
      rc_at_backoff="$(supervise_field A2A_RECEIVER_RESTART_COUNT)"
      saw_backoff=1
      break
    fi
  done

  local audit
  audit="$(audit_log_text)"
  smoke_assert_eq "1" "$saw_backoff" \
    "a transient tick BACKED OFF (alarm=bind_backoff) instead of respawning"
  smoke_assert_contains "$audit" "a2a_receiver_bind_backoff" \
    "a2a_receiver_bind_backoff audit row emitted for the backed-off tick"
  smoke_assert_eq "transient" "$(supervise_field A2A_RECEIVER_ERROR_CLASS)" \
    "the backed-off failure is classified transient (config+secret valid, bind unavailable)"
  # The anti-thrash: the backoff tick did NOT increment the restart counter.
  smoke_assert_eq "${prev_rc:-x}" "${rc_at_backoff:-y}" \
    "the backoff tick did NOT respawn — restart counter held at ${prev_rc:-?} (the anti-thrash)"

  # Reset the knobs for the next checks.
  export BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS=1
  export BRIDGE_A2A_RECEIVER_BACKOFF_CAP_SECONDS=4
  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3

  # The receiver never bound (unprovable) — fail-closed held throughout.
  local rc=0
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null || rc=$?
  smoke_assert_match "$rc" '^[1-9]' "receiver never bound (unprovable tailnet config — fail-closed held)"
}

# --- Check (a2): consecutive transient failures OPEN the circuit (one task) ---
# Unprovable tailnet bind + absent tailscale CLI, with a TINY backoff base so
# `retry` fires every fast test tick and the transient counter climbs to the
# (low) open threshold. Once it does, the circuit OPENS: alarm=circuit_open, a
# a2a_receiver_circuit_open audit, and EXACTLY ONE escalation admin task
# (escalate-once-per-cooldown) — auto-restart is then PAUSED (no thrash).
check_transient_opens_circuit() {
  reset_scenario_state
  register_admin_agent

  export BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS=1
  export BRIDGE_A2A_RECEIVER_BACKOFF_CAP_SECONDS=4
  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3

  A2A_PORT="$(pick_free_port)"
  write_unprovable_config "$A2A_PORT"

  # The inter-tick gap (seconds) exceeds the tiny backoff, so `retry` fires each
  # tick and consec_transient climbs 1 -> 2 -> 3 -> open. 12 ticks is a
  # comfortable ceiling.
  local i alarm consec
  for (( i = 0; i < 12; i++ )); do
    run_sync_no_tailnet >/dev/null
    alarm="$(supervise_field A2A_RECEIVER_ALARM)"
    [[ "$alarm" == "circuit_open" ]] && break
  done

  local audit
  audit="$(audit_log_text)"
  alarm="$(supervise_field A2A_RECEIVER_ALARM)"
  smoke_assert_eq "circuit_open" "$alarm" \
    "circuit breaker OPENED after consecutive transient bind failures (auto-restart paused)"
  smoke_assert_contains "$audit" "a2a_receiver_circuit_open" \
    "a2a_receiver_circuit_open audit row emitted when the breaker opens"
  smoke_assert_eq "transient" "$(supervise_field A2A_RECEIVER_ERROR_CLASS)" \
    "supervise.env records error_class=transient for the open breaker"
  consec="$(supervise_field A2A_RECEIVER_CONSEC_TRANSIENT)"
  [[ "$consec" =~ ^[0-9]+$ ]] || smoke_fail "consec_transient not numeric: $consec"
  (( consec >= 3 )) || smoke_fail "consec_transient ($consec) did not reach the open threshold (3)"

  # EXACTLY ONE admin task filed (escalate-once-per-cooldown — no task thrash).
  local task_count
  task_count="$(bash "$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer 2>/dev/null | grep -c 'circuit OPEN' || true)"
  [[ "$task_count" =~ ^[0-9]+$ ]] || task_count=0
  smoke_assert_eq "1" "$task_count" \
    "exactly ONE circuit-open admin task filed (escalate-once-per-cooldown, no task thrash)"

  # The receiver NEVER bound (unprovable) — fail-closed proof held throughout.
  local rc=0
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null || rc=$?
  smoke_assert_match "$rc" '^[1-9]' "receiver never bound (unprovable tailnet config — fail-closed held)"
}

# --- Check (b): auth/config error is HELD, not thrashed ----------------------
# Empty-secret peer config. The fail-closed preflight refuses to start
# (peer_no_secret, phase=config) -> classified auth_config -> the supervisor
# HOLDS (a2a_receiver_auth_config_hold) instead of routing it through the
# transient backoff. consec_transient must stay 0 (it was NOT counted as a
# transient bind failure).
check_auth_config_hold() {
  reset_scenario_state
  register_admin_agent

  local port
  port="$(pick_free_port)"
  write_empty_secret_config "$port"

  # A couple of ticks: the FIRST attempt fails the config gate and is classified
  # auth_config; the next tick sees the held class and re-holds (no backoff
  # thrash). The tailscale CLI is irrelevant here (config fails before bind).
  local i
  for (( i = 0; i < 3; i++ )); do
    run_sync >/dev/null
  done

  local audit
  audit="$(audit_log_text)"
  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ERROR_CLASS)" \
    "empty-secret config classified error_class=auth_config (NON-transient)"
  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ALARM)" \
    "supervise.env alarm = auth_config (HELD, not crashloop/bind_backoff)"
  smoke_assert_contains "$audit" "a2a_receiver_auth_config_hold" \
    "a2a_receiver_auth_config_hold audit row emitted for the config error"
  # CRITICAL anti-thrash: an auth/config error must NOT be counted as a
  # transient bind failure, so it never climbs the backoff/breaker path.
  smoke_assert_eq "0" "$(supervise_field A2A_RECEIVER_CONSEC_TRANSIENT)" \
    "auth/config error did NOT increment the transient-failure counter (no backoff thrash)"
  smoke_assert_not_contains "$audit" "a2a_receiver_bind_backoff" \
    "auth/config error did NOT enter the transient backoff path"
  smoke_assert_not_contains "$audit" "a2a_receiver_circuit_open" \
    "auth/config error did NOT open the transient circuit breaker"

  # The receiver never came up (empty secret refused) — fail-closed held.
  local rc=0
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$port" 2>/dev/null || rc=$?
  smoke_assert_match "$rc" '^[1-9]' "receiver never bound under an empty-secret config (fail-closed held)"
}

# --- Check (b2): a MALFORMED config is held as auth_config, even after a stale
#                transient row (codex review finding) ------------------------
# load_config() failures (config_parse / config_missing / config_perms /
# config_shape) happen at the CONFIG phase, before any bind. Pre-fix
# cmd_preflight did NOT audit them with phase=config, so the exit-cause
# classifier saw no terminal row for the failure — and if a STALE bind-phase
# (transient) row from an EARLIER episode was still in a2a-handoff.jsonl, it
# would inherit it and mis-route the config error into the transient backoff
# thrash. This check SEEDS exactly that stale transient row, then drives a
# malformed-config tick, and asserts the result is held as auth_config (NOT
# transient). Pre-fix it classifies transient and enters the backoff path.
check_malformed_config_held_after_stale_transient() {
  reset_scenario_state
  register_admin_agent
  A2A_PORT="$(pick_free_port)"

  # Seed a STALE bind-phase (transient) terminal row into the receiver jsonl —
  # as if an earlier tailnet-down episode had logged it. The malformed-config
  # failure below must NOT inherit this row's classification.
  mkdir -p "$BRIDGE_LOG_DIR"
  printf '%s\n' '{"event":"startup_fail","code":"tailscale_unavailable","phase":"bind","detail":"earlier tailnet blip"}' \
    >"$BRIDGE_LOG_DIR/a2a-handoff.jsonl"

  write_malformed_config

  # The preflight (driven by the supervised restart) re-loads the config; with
  # the fix it appends a fresh phase=config row that the classifier mines as the
  # LAST terminal event -> auth_config. Drive a couple of ticks.
  local i
  for (( i = 0; i < 3; i++ )); do
    run_sync >/dev/null
  done

  local audit
  audit="$(audit_log_text)"
  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ERROR_CLASS)" \
    "malformed config (config_parse) classified auth_config — NOT inheriting the stale transient row"
  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ALARM)" \
    "malformed config HELD (alarm=auth_config), not routed into the backoff thrash"
  smoke_assert_contains "$audit" "a2a_receiver_auth_config_hold" \
    "a2a_receiver_auth_config_hold audit row emitted for the malformed config"
  smoke_assert_eq "0" "$(supervise_field A2A_RECEIVER_CONSEC_TRANSIENT)" \
    "malformed config did NOT increment the transient-failure counter (no backoff thrash)"
  smoke_assert_not_contains "$audit" "a2a_receiver_bind_backoff" \
    "malformed config did NOT enter the transient backoff path"

  # And the receiver never came up (config unloadable) — fail-closed held.
  local rc=0
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null || rc=$?
  smoke_assert_match "$rc" '^[1-9]' "receiver never bound under a malformed config (fail-closed held)"
}

# --- Check (b3): a malformed config is HELD even when the breaker is ALREADY
#                OPEN on transient (codex r2 finding) -------------------------
# The deeper variant: state already carries an OPEN transient breaker
# (error_class=transient, consec_transient >= threshold) from an earlier
# tailnet-down episode. The operator then breaks the config (malformed). The
# per-tick decision runs from the PERSISTED class BEFORE the restart path emits
# this config's own phase=config row — so a naive tick would return `open`
# (transient) and hold the malformed config as circuit_open until a window
# reset. The fix classifies the LIVE unloadable config as auth_config at the
# exit-cause layer (authoritative now-signal), so this tick re-keys (class
# changed transient->auth_config => consec_transient reset) and HOLDS it as
# auth_config. Pre-fix it stays circuit_open / transient.
check_malformed_config_overrides_open_transient_breaker() {
  reset_scenario_state
  register_admin_agent
  A2A_PORT="$(pick_free_port)"

  # Stale transient bind-phase row, as if the prior episode was tailnet-down.
  mkdir -p "$BRIDGE_LOG_DIR"
  printf '%s\n' '{"event":"startup_fail","code":"tailscale_unavailable","phase":"bind","detail":"earlier tailnet blip"}' \
    >"$BRIDGE_LOG_DIR/a2a-handoff.jsonl"

  # Seed an ALREADY-OPEN transient breaker (consec >= threshold). LAST_RESTART_TS
  # is NOW so the window reset does NOT pre-emptively clear it — the fix, not the
  # window reset, must be what holds the malformed config.
  local now_ts
  now_ts="$(date +%s)"
  {
    printf 'A2A_RECEIVER_RESTART_COUNT=1\n'
    printf 'A2A_RECEIVER_LAST_RESTART_TS=%s\n' "$now_ts"
    printf 'A2A_RECEIVER_CONSEC_UNHEALTHY=0\n'
    printf 'A2A_RECEIVER_ALARM=circuit_open\n'
    printf 'A2A_RECEIVER_LAST_REASON=bind_proof_failed\n'
    printf 'A2A_RECEIVER_LAST_EXIT_EVENT=startup_fail\n'
    printf 'A2A_RECEIVER_LAST_EXIT_DETAIL=seeded\n'
    printf 'A2A_RECEIVER_LAST_ADMIN_TASK_TS=0\n'
    printf 'A2A_RECEIVER_ERROR_CLASS=transient\n'
    printf 'A2A_RECEIVER_BREAKER_KEY=deadbeefdeadbeef\n'
    printf 'A2A_RECEIVER_CONSEC_TRANSIENT=5\n'
  } >"$(supervise_state)"
  chmod 0600 "$(supervise_state)" 2>/dev/null || true

  write_malformed_config
  # Threshold 3 so the seeded consec=5 is OVER the open threshold (proves the
  # decision would say `open` for a transient class — the fix must override it).
  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3

  run_sync >/dev/null

  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ERROR_CLASS)" \
    "unloadable config reclassified auth_config even with an already-open transient breaker"
  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ALARM)" \
    "malformed config HELD as auth_config (NOT left as circuit_open / transient)"
  smoke_assert_eq "0" "$(supervise_field A2A_RECEIVER_CONSEC_TRANSIENT)" \
    "class change transient->auth_config reset the stale transient counter"
  local audit
  audit="$(audit_log_text)"
  smoke_assert_contains "$audit" "a2a_receiver_auth_config_hold" \
    "a2a_receiver_auth_config_hold emitted (not a fresh circuit_open) for the malformed config"

  # --- (b3b) the config_perms variant (codex r3): a VALID-JSON config that is
  # too-open (0644) is rejected by the receiver's load_config() as config_perms.
  # _config_unloadable reuses the real load_config(), so it catches this too —
  # not just a JSON parse error. Same already-open-transient-breaker setup.
  reset_scenario_state
  register_admin_agent
  A2A_PORT="$(pick_free_port)"
  mkdir -p "$BRIDGE_LOG_DIR"
  printf '%s\n' '{"event":"startup_fail","code":"tailscale_unavailable","phase":"bind","detail":"earlier tailnet blip"}' \
    >"$BRIDGE_LOG_DIR/a2a-handoff.jsonl"
  now_ts="$(date +%s)"
  {
    printf 'A2A_RECEIVER_RESTART_COUNT=1\n'
    printf 'A2A_RECEIVER_LAST_RESTART_TS=%s\n' "$now_ts"
    printf 'A2A_RECEIVER_CONSEC_UNHEALTHY=0\n'
    printf 'A2A_RECEIVER_ALARM=circuit_open\n'
    printf 'A2A_RECEIVER_LAST_REASON=bind_proof_failed\n'
    printf 'A2A_RECEIVER_LAST_EXIT_EVENT=startup_fail\n'
    printf 'A2A_RECEIVER_LAST_EXIT_DETAIL=seeded\n'
    printf 'A2A_RECEIVER_LAST_ADMIN_TASK_TS=0\n'
    printf 'A2A_RECEIVER_ERROR_CLASS=transient\n'
    printf 'A2A_RECEIVER_BREAKER_KEY=deadbeefdeadbeef\n'
    printf 'A2A_RECEIVER_CONSEC_TRANSIENT=5\n'
  } >"$(supervise_state)"
  chmod 0600 "$(supervise_state)" 2>/dev/null || true

  # A VALID config but chmod 0644 (too open) — load_config() raises config_perms.
  write_loopback_config "$A2A_PORT"
  chmod 0644 "$(config_path)"
  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3

  run_sync >/dev/null

  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ERROR_CLASS)" \
    "(b3b) too-open (0644) config reclassified auth_config (config_perms) over the open transient breaker"
  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ALARM)" \
    "(b3b) config_perms HELD as auth_config (NOT left as circuit_open)"
  audit="$(audit_log_text)"
  smoke_assert_contains "$audit" "a2a_receiver_auth_config_hold" \
    "(b3b) a2a_receiver_auth_config_hold emitted for the config_perms case"

  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3
}

# --- Check (b4): an EMPTY-PEER-SECRET config is HELD as auth_config even when
#                the breaker is ALREADY OPEN on transient (codex r1-rc2 finding)
# This is the gap codex's rc2 r1 review flagged: the current-state override
# reused only load_config(), NOT the receiver's SECRET gate. An empty-secret
# config is mode 0600, valid JSON, valid shape — so load_config() SUCCEEDS and
# the load_config-only override returns "config loads fine" -> NO override. With
# a stale bind-phase (transient) jsonl row + an already-open transient breaker,
# the per-tick decision would then return `open` (transient) and keep the
# receiver backing off / circuit-open instead of HOLDING as auth_config and
# surfacing the real misconfig (validate_config_peer_secrets => peer_no_secret).
# The fix runs validate_config_peer_secrets(side="receiver") AFTER load_config()
# in the override, so a loadable-but-secret-less config is reclassified
# auth_config NOW (class transient->auth_config => consec_transient reset =>
# decision `hold`). TEETH: reverting to the load_config-only override makes this
# classify transient and the decision `open`, FAILING the asserts below.
check_empty_secret_overrides_open_transient_breaker() {
  reset_scenario_state
  register_admin_agent
  A2A_PORT="$(pick_free_port)"

  # Stale transient bind-phase row, as if the prior episode was tailnet-down.
  mkdir -p "$BRIDGE_LOG_DIR"
  printf '%s\n' '{"event":"startup_fail","code":"tailscale_unavailable","phase":"bind","detail":"earlier tailnet blip"}' \
    >"$BRIDGE_LOG_DIR/a2a-handoff.jsonl"

  # Seed an ALREADY-OPEN transient breaker (consec >= threshold). LAST_RESTART_TS
  # is NOW so the window reset does NOT pre-emptively clear it — the SECRET-gate
  # reclassification, not the window reset, must be what holds the bad config.
  local now_ts
  now_ts="$(date +%s)"
  {
    printf 'A2A_RECEIVER_RESTART_COUNT=1\n'
    printf 'A2A_RECEIVER_LAST_RESTART_TS=%s\n' "$now_ts"
    printf 'A2A_RECEIVER_CONSEC_UNHEALTHY=0\n'
    printf 'A2A_RECEIVER_ALARM=circuit_open\n'
    printf 'A2A_RECEIVER_LAST_REASON=bind_proof_failed\n'
    printf 'A2A_RECEIVER_LAST_EXIT_EVENT=startup_fail\n'
    printf 'A2A_RECEIVER_LAST_EXIT_DETAIL=seeded\n'
    printf 'A2A_RECEIVER_LAST_ADMIN_TASK_TS=0\n'
    printf 'A2A_RECEIVER_ERROR_CLASS=transient\n'
    printf 'A2A_RECEIVER_BREAKER_KEY=deadbeefdeadbeef\n'
    printf 'A2A_RECEIVER_CONSEC_TRANSIENT=5\n'
  } >"$(supervise_state)"
  chmod 0600 "$(supervise_state)" 2>/dev/null || true

  # A LOADABLE config (mode 0600, valid JSON + shape) whose only fault is an
  # EMPTY peer secret. load_config() passes; only validate_config_peer_secrets
  # (peer_no_secret) catches it. BRIDGE_A2A_ALLOW_TEST_BIND alone does NOT relax
  # the secret gate (only the paired DEV_INSECURE_BIND does, never set here).
  write_empty_secret_config "$A2A_PORT"
  # Threshold 3 so the seeded consec=5 is OVER the open threshold (proves the
  # decision WOULD say `open` for a transient class — the fix must override it).
  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3

  run_sync >/dev/null

  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ERROR_CLASS)" \
    "(b4) loadable empty-secret config reclassified auth_config (peer_no_secret) over the open transient breaker"
  smoke_assert_eq "auth_config" "$(supervise_field A2A_RECEIVER_ALARM)" \
    "(b4) empty-secret config HELD as auth_config (NOT left as circuit_open / open / backoff)"
  smoke_assert_eq "0" "$(supervise_field A2A_RECEIVER_CONSEC_TRANSIENT)" \
    "(b4) class change transient->auth_config reset the stale transient counter"
  local audit
  audit="$(audit_log_text)"
  smoke_assert_contains "$audit" "a2a_receiver_auth_config_hold" \
    "(b4) a2a_receiver_auth_config_hold emitted (NOT a fresh circuit_open) for the empty-secret config"
  smoke_assert_not_contains "$audit" "a2a_receiver_bind_backoff" \
    "(b4) empty-secret config did NOT enter the transient backoff path"

  # Direct teeth on the helper: the SAME stale-transient jsonl + the SAME
  # loadable empty-secret config must classify auth_config (NOT transient). A
  # load_config-only override leaves this `transient`; the secret-gate override
  # flips it to auth_config. This pins the fix at the classifier boundary
  # independent of the daemon decision wiring.
  local classify_out
  classify_out="$(python3 "$SCRIPT_DIR/../../lib/daemon-helpers/a2a-receiver-exit-cause.py" \
    "$BRIDGE_STATE_DIR/handoff/b4-classify.json" \
    "$BRIDGE_LOG_DIR/a2a-handoffd.log" \
    "$BRIDGE_LOG_DIR/a2a-handoff.jsonl" \
    bind_proof_failed 123 1000 20 "$(config_path)" 2>/dev/null || true)"
  smoke_assert_match "$classify_out" 'auth_config' \
    "(b4) exit-cause classifier: stale-transient row + loadable empty-secret config -> auth_config (secret-gate override, NOT load_config-only)"

  # The receiver never came up (empty secret refused) — fail-closed held.
  local rc=0
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null || rc=$?
  smoke_assert_match "$rc" '^[1-9]' "(b4) receiver never bound under an empty-secret config (fail-closed held)"

  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3
}

# --- Check (c): a successful bind RESETS the breaker -------------------------
# The "successful bind resets the breaker" contract has two reachable proofs in
# an isolated harness (a real loopback receiver is deliberately NOT seen as
# "healthy" by the supervise tick's probe — #1414 scrubs the test-bind escape
# hatch from the supervisor's healthz subprocess so it always runs the
# PRODUCTION bind contract, which refuses loopback; that scrub is a security
# feature this PR must not weaken). So we prove the reset via the two paths that
# ARE reachable without a real tailnet:
#   (c1) the healthy-probe reset CODE resets consec_transient + error_class — we
#        assert this directly against the function source so the contract is
#        pinned even though a loopback bind cannot exercise it live (SKIP-loud).
#   (c2) the restart-WINDOW reset clears the breaker (down-path, fully live).
# Both share the "next transient failure starts a fresh backoff schedule"
# rationale. A live healthy-probe reset is covered by the cross-bridge VM
# acceptance on a real tailnet, not by this isolated smoke.
check_recovery_resets_breaker() {
  reset_scenario_state

  # (c1) Static proof: the healthy-probe branch resets BOTH the transient
  # counter and the error_class. Pin it against the source so a future edit
  # that drops the breaker reset from the healthy path is caught here. (We
  # SKIP-loud the live loopback exercise — see the header rationale.)
  smoke_skip "live healthy-probe reset on loopback" \
    "loopback bind is refused by the #1414-scrubbed supervisor probe; covered on a real tailnet"
  local healthy_block
  healthy_block="$(awk '/receiver healthy.*clearing counters/{f=1} f{print} /return 0/{if(f){exit}}' \
    "$SMOKE_REPO_ROOT/bridge-daemon.sh")"
  smoke_assert_contains "$healthy_block" "consec_transient=0" \
    "(c1) the healthy-probe reset zeroes consec_transient (breaker reset on healthy bind)"
  smoke_assert_contains "$healthy_block" "prev_error_class=\"\"" \
    "(c1) the healthy-probe reset clears the persisted error_class"

  # --- (c2) the restart-WINDOW reset ALSO clears the breaker -----------------
  # A host that crossed the restart window QUIET (no receiver, stale state with
  # an old LAST_RESTART_TS) must not inherit a near-open transient counter on
  # its next failure. Seed an OLD last-restart ts so the window-elapsed reset
  # fires; the breaker (consec_transient + error_class) must clear too — the
  # same "fresh schedule" rationale as the healthy-probe reset.
  reset_scenario_state
  # An UNPROVABLE bind so the post-reset restart FAILS — this ISOLATES the
  # window reset from the successful-restart reset (a loopback config would let
  # the restart succeed and zero the counter anyway, masking the window reset).
  # With an old LAST_RESTART_TS the window reset clears the seeded breaker to 0
  # FIRST, then the single failed restart can only push the FRESH counter to 1.
  # So consec_transient < the seeded 2 proves the window reset cleared it. (Were
  # the window reset NOT clearing the breaker, the seeded 2 would climb to 3.)
  A2A_PORT="$(pick_free_port)"
  write_unprovable_config "$A2A_PORT"
  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=99
  {
    printf 'A2A_RECEIVER_RESTART_COUNT=2\n'
    printf 'A2A_RECEIVER_LAST_RESTART_TS=1\n'
    printf 'A2A_RECEIVER_CONSEC_UNHEALTHY=0\n'
    printf 'A2A_RECEIVER_ALARM=bind_backoff\n'
    printf 'A2A_RECEIVER_LAST_REASON=bind_proof_failed\n'
    printf 'A2A_RECEIVER_LAST_EXIT_EVENT=startup_fail\n'
    printf 'A2A_RECEIVER_LAST_EXIT_DETAIL=seeded\n'
    printf 'A2A_RECEIVER_LAST_ADMIN_TASK_TS=0\n'
    printf 'A2A_RECEIVER_ERROR_CLASS=transient\n'
    printf 'A2A_RECEIVER_BREAKER_KEY=deadbeefdeadbeef\n'
    printf 'A2A_RECEIVER_CONSEC_TRANSIENT=2\n'
  } >"$(supervise_state)"
  chmod 0600 "$(supervise_state)" 2>/dev/null || true

  # One tick: receiver down + old last-restart-ts -> window reset clears the
  # breaker FIRST, then the failed restart re-classifies fresh (consec -> 1).
  run_sync_no_tailnet >/dev/null
  local consec_after
  consec_after="$(supervise_field A2A_RECEIVER_CONSEC_TRANSIENT)"
  [[ "$consec_after" =~ ^[0-9]+$ ]] || consec_after=0
  (( consec_after < 2 )) || smoke_fail \
    "(c2) restart-window reset did NOT clear the stale breaker (consec_transient still $consec_after >= seeded 2)"
  smoke_assert_match "$consec_after" '^[01]$' \
    "(c2) restart-window reset cleared the stale breaker (consec_transient restarted from a fresh count)"

  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  HANDOFFD_PID=""
}

# --- Check (d): fail-closed INTACT — the teeth the healthz change must NOT cut
# (1) the receiver still REFUSES the unprovable tailnet bind (already covered by
#     (a)/(b) — the port never comes up); here we additionally prove the LIVE
#     accept-path boundary is unchanged:
# (2) a bad HMAC signature still -> 401, and
# (3) an unknown/non-allowlisted peer still -> 403,
# against a real loopback receiver. PR-4 touched only supervision, so these MUST
# still hold exactly as a2a-cross-bridge.sh pins them.
check_fail_closed_intact() {
  reset_scenario_state

  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle
  HANDOFFD_PID="$(receiver_pid_now)"

  local base="http://127.0.0.1:$A2A_PORT"

  # Bad HMAC -> 401 (the auth gate the supervision change must not loosen).
  local out_auth
  out_auth="$(python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" auth-fail "$base" bridge-a "$A2A_SECRET" 2>/dev/null || true)"
  smoke_assert_contains "$out_auth" "STATUS=401" \
    "fail-closed INTACT: bad HMAC still -> 401 (healthz change did not loosen auth)"

  # Non-allowlisted target -> 403 (the allowlist gate is unchanged).
  local out_allow
  out_allow="$(python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" allowlist-fail "$base" bridge-a "$A2A_SECRET" 2>/dev/null || true)"
  smoke_assert_contains "$out_allow" "STATUS=403" \
    "fail-closed INTACT: non-allowlisted target still -> 403 (allowlist unchanged)"

  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  HANDOFFD_PID=""
}

# --- Check (e): escalation task-create FAILURE is audited, not swallowed -----
# Drive the circuit OPEN with an admin configured but NO agent-bridge CLI
# reachable for the escalation (point BRIDGE_HOME's agent-bridge + SCRIPT_DIR's
# agent-bridge out of reach by running the tick with a sabotaged PATH/dir is
# brittle; instead we register an admin whose task-create will FAIL because the
# target agent does not exist in the roster). The escalate helper must emit a
# a2a_receiver_escalation_task_create_failed audit AND retain the old
# last_admin_task_ts (so a later eligible tick retries).
check_escalation_task_create_failure_audited() {
  reset_scenario_state

  # Admin id points at an agent that is NOT in the roster -> task create fails.
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  {
    printf 'BRIDGE_ADMIN_AGENT_ID="ghost-admin-not-in-roster"\n'
  } >"$BRIDGE_ROSTER_LOCAL_FILE"

  # Tiny backoff so the circuit opens (and the escalation is attempted) quickly.
  export BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS=1
  export BRIDGE_A2A_RECEIVER_BACKOFF_CAP_SECONDS=4
  export BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD=3

  A2A_PORT="$(pick_free_port)"
  write_unprovable_config "$A2A_PORT"

  local i alarm
  for (( i = 0; i < 12; i++ )); do
    run_sync_no_tailnet >/dev/null
    alarm="$(supervise_field A2A_RECEIVER_ALARM)"
    [[ "$alarm" == "circuit_open" ]] && break
  done

  alarm="$(supervise_field A2A_RECEIVER_ALARM)"
  smoke_assert_eq "circuit_open" "$alarm" "circuit opened (precondition for the escalation attempt)"

  local audit
  audit="$(audit_log_text)"
  smoke_assert_contains "$audit" "a2a_receiver_escalation_task_create_failed" \
    "task-create failure emits a2a_receiver_escalation_task_create_failed (NOT swallowed by || true)"
  # The escalation ts must NOT have advanced (it is retained for a later retry).
  smoke_assert_eq "0" "$(supervise_field A2A_RECEIVER_LAST_ADMIN_TASK_TS)" \
    "last_admin_task_ts retained at 0 after a failed task-create (retry on next eligible tick)"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "1563-pr4-a2a-receiver-healthz"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  NO_TAILSCALE="$SMOKE_TMP_ROOT/no-such-tailscale"

  smoke_run "policy helpers: backoff + breaker + decision word (unit)" check_policy_helpers
  smoke_run "exit-cause classifier tags transient vs auth_config" check_exit_cause_classifier
  smoke_run "(a1) transient bind failure BACKS OFF (no immediate respawn)" check_transient_backs_off
  smoke_run "(a2) consecutive transient failures OPEN the circuit (one escalation)" check_transient_opens_circuit
  smoke_run "(b) auth/config error is HELD, not thrashed through the backoff path" check_auth_config_hold
  smoke_run "(b2) malformed config held as auth_config even after a stale transient row" check_malformed_config_held_after_stale_transient
  smoke_run "(b3) malformed config overrides an ALREADY-OPEN transient breaker" check_malformed_config_overrides_open_transient_breaker
  smoke_run "(b4) loadable empty-secret config overrides an ALREADY-OPEN transient breaker (secret gate)" check_empty_secret_overrides_open_transient_breaker
  smoke_run "(c) a successful bind RESETS the circuit breaker" check_recovery_resets_breaker
  smoke_run "(d) fail-closed INTACT: bad HMAC -> 401, unknown peer -> 403" check_fail_closed_intact
  smoke_run "(e) escalation task-create failure is audited + retried (not swallowed)" check_escalation_task_create_failure_audited

  smoke_log "passed"
}

main "$@"
