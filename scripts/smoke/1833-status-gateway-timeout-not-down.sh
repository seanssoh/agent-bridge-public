#!/usr/bin/env bash
#
# Issue #1833 — `bridge-daemon.sh status` health must come from daemon-PID
# liveness, never from a queue-gateway response.
#
# Field symptom: when an iso v2 agent woke from idle, its first queue-gateway
# call returned "queue gateway timed out waiting for daemon" and
# `agb status` / `bridge-daemon.sh status` then surfaced `health=down` — while
# the daemon was CONFIRMED alive (same PID stable for hours, watchdog restart
# count 0, no tick gap). The false `down` drove false-alarm escalations.
#
# Fix under test (A3, consumes the A1 #1837/#1840 primitive): the status
# renderer derives health from `bridge_daemon_liveness` (lib/bridge-state.sh),
# a tri-state pidfile+cmdline check that reuses `gateway_daemon_liveness`
# (bridge-queue-gateway.py `daemon-liveness`) — NOT from whether a gateway
# call happened to time out. Contract pinned here:
#
#   1. LIVE daemon pid + a real, simulated gateway-call timeout
#        → status reports health=ok (NOT down), daemon_liveness=up.
#   2. Genuinely DEAD recorded pid (no live daemon process)
#        → status reports health=down, daemon_liveness=down.
#   3. UNREADABLE pidfile (the iso v2 boundary shape)
#        → status reports health=unknown (NOT down), daemon_liveness=unknown.
#
# The "live daemon" is a daemon-shaped sleeper launched as
# `<BRIDGE_HOME>/bridge-daemon.sh run` so both the shell resolver's pgrep
# pattern and the primitive's position-anchored cmdline proof accept it
# (same stand-in pattern as scripts/smoke/1563-daemon-singleton.sh).

set -euo pipefail

SMOKE_NAME="1833-status-gateway-timeout-not-down"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap 'cleanup' EXIT

FAKE_DAEMON_PID=""

cleanup() {
  if [[ -n "$FAKE_DAEMON_PID" ]]; then
    kill "$FAKE_DAEMON_PID" 2>/dev/null || true
    wait "$FAKE_DAEMON_PID" 2>/dev/null || true
  fi
  # Restore readability so the temp-root cleanup can delete the tree.
  chmod 0644 "$BRIDGE_DAEMON_PID_FILE" 2>/dev/null || true
  smoke_cleanup_temp_root
}

run_status() {
  # The real repo entry point against the isolated home. BRIDGE_DAEMON_PID_FILE
  # is pinned explicitly: without it the daemon's marker-aware precedence could
  # resolve the operator's live pidfile and leak live state into the smoke.
  env \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_DAEMON_PID_FILE="$BRIDGE_DAEMON_PID_FILE" \
    BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
    BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
    BRIDGE_SKIP_PLUGIN_LIVENESS=1 \
    bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" status 2>/dev/null || true
}

live_daemon_plus_gateway_timeout_not_down() {
  # Stand-in daemon at the canonical <home>/bridge-daemon.sh path, launched as
  # `bash <home>/bridge-daemon.sh run` so its argv satisfies both the shell
  # resolver's pgrep/cmdline guard and the primitive's position anchor. The
  # body loops short sleeps (NOT one long `sleep`) and stdio is detached to
  # /dev/null: a long-lived sleep child orphaned by `kill <wrapper>` would
  # otherwise inherit the smoke's stdout pipe and hold the harness open.
  printf '#!/usr/bin/env bash\nwhile :; do sleep 5; done\n' >"$BRIDGE_HOME/bridge-daemon.sh"
  chmod +x "$BRIDGE_HOME/bridge-daemon.sh"
  bash "$BRIDGE_HOME/bridge-daemon.sh" run </dev/null >/dev/null 2>&1 &
  FAKE_DAEMON_PID=$!
  printf '%s\n' "$FAKE_DAEMON_PID" >"$BRIDGE_DAEMON_PID_FILE"
  date +%s >"$BRIDGE_STATE_DIR/daemon.heartbeat"

  # Real simulated gateway timeout: a client call against a gateway root no
  # daemon is serving, minimum base timeout, zero read-retries. This is the
  # exact "queue gateway timed out waiting for daemon" the iso agent saw.
  local gw_root="$BRIDGE_STATE_DIR/queue-gateway"
  mkdir -p "$gw_root"
  local client_rc=0 client_err=""
  client_err="$(BRIDGE_QUEUE_GATEWAY_READ_RETRIES=0 \
    python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" client \
      --root "$gw_root" --agent tester --timeout 1 -- inbox tester 2>&1)" \
    || client_rc=$?
  [[ "$client_rc" -ne 0 ]] || smoke_fail "expected the gateway client call to time out (rc=0)"
  smoke_assert_contains "$client_err" "queue gateway timed out waiting for daemon" \
    "the simulated gateway call raises the exact #1833 timeout"

  # The daemon process is alive and the gateway call just timed out: status
  # must NOT report down.
  local out
  out="$(run_status)"
  smoke_assert_contains "$out" "daemon_liveness=up" \
    "liveness anchored on the daemon pid reports up despite the gateway timeout"
  smoke_assert_contains "$out" "health=ok" \
    "health=ok with a live daemon pid + fresh tick (gateway timeout ignored)"
  smoke_assert_not_contains "$out" "health=down" \
    "a gateway-call timeout alone never yields health=down for a live daemon"
  smoke_assert_contains "$out" "running pid=" \
    "headline keeps the running-pid grep grammar for a live daemon"

  kill "$FAKE_DAEMON_PID" 2>/dev/null || true
  wait "$FAKE_DAEMON_PID" 2>/dev/null || true
}

dead_pid_reports_down() {
  # FAKE_DAEMON_PID was killed and reaped above; its recorded pid is now a
  # genuinely dead pid (and even a recycled pid would fail the cmdline proof).
  printf '%s\n' "$FAKE_DAEMON_PID" >"$BRIDGE_DAEMON_PID_FILE"
  FAKE_DAEMON_PID=""
  local out
  out="$(run_status)"
  smoke_assert_contains "$out" "daemon_liveness=down" \
    "a dead recorded pid is a genuine down"
  smoke_assert_contains "$out" "health=down" \
    "health=down only for a provably dead daemon"
}

unreadable_pidfile_reports_unknown() {
  # The iso v2 boundary shape: the pidfile exists but this UID cannot read
  # it. Root can read through mode 0000, so skip there (same guard as other
  # permission smokes).
  if [[ "$(id -u)" -eq 0 ]]; then
    smoke_log "skip: running as root — mode 0000 does not block reads"
    return 0
  fi
  printf '%s\n' "99999" >"$BRIDGE_DAEMON_PID_FILE"
  chmod 0000 "$BRIDGE_DAEMON_PID_FILE"
  local out
  out="$(run_status)"
  chmod 0644 "$BRIDGE_DAEMON_PID_FILE"
  smoke_assert_contains "$out" "daemon_liveness=unknown" \
    "an unreadable pidfile is a visibility boundary, not a verdict"
  smoke_assert_contains "$out" "health=unknown" \
    "health=unknown across the iso boundary"
  smoke_assert_not_contains "$out" "health=down" \
    "an unreadable pidfile never false-reports down (#1833)"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  export BRIDGE_DAEMON_PID_FILE="$BRIDGE_STATE_DIR/daemon.pid"

  smoke_run "live daemon + gateway timeout -> health=ok, not down (#1833)" \
    live_daemon_plus_gateway_timeout_not_down
  smoke_run "dead recorded pid -> health=down (genuine crash still alarms)" \
    dead_pid_reports_down
  smoke_run "unreadable pidfile -> health=unknown, never down (iso boundary)" \
    unreadable_pidfile_reports_unknown

  smoke_log "PASS: $SMOKE_NAME"
}

main "$@"
