#!/usr/bin/env bash

# Issue #779: lock the contract for the channel runtime LISTEN probe.
# bridge_agent_channel_runtime_ready_for_item must, in addition to its
# pre-existing file/key checks, refuse to report runtime_ready=true for a
# teams channel whose webhook listener is NOT bound on the configured
# TCP port. The new bridge_port_is_listening helper does the probe and
# is reusable by Track E.
#
# The smoke runs on both Linux and macOS — ss (iproute2) is the Linux
# probe, lsof is the macOS fallback. If neither is available we skip
# (matches the helper's fail-open behavior on minimal hosts).

set -euo pipefail

SMOKE_NAME="channel-runtime-listen-probe"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

LISTENER_PID=""
LISTENER_PORT=""

cleanup() {
  if [[ -n "$LISTENER_PID" ]]; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

source_bridge_lib() {
  # shellcheck source=bridge-lib.sh
  source "$SMOKE_REPO_ROOT/bridge-lib.sh"
  bridge_load_roster
}

WORKER="worker779"
WORKDIR=""
TEAMS_DIR=""
TEAMS_ENV=""

register_worker() {
  WORKDIR="$BRIDGE_AGENT_ROOT_V2/$WORKER/workdir"
  TEAMS_DIR="$WORKDIR/.teams"
  TEAMS_ENV="$TEAMS_DIR/.env"
  mkdir -p "$WORKDIR" "$TEAMS_DIR"
  bridge_add_agent_id_if_missing "$WORKER"
  BRIDGE_AGENT_ENGINE["$WORKER"]="claude"
  BRIDGE_AGENT_SOURCE["$WORKER"]="static"
  BRIDGE_AGENT_SESSION["$WORKER"]="$WORKER-session"
  BRIDGE_AGENT_WORKDIR["$WORKER"]="$WORKDIR"
  BRIDGE_AGENT_LOOP["$WORKER"]=0
  BRIDGE_AGENT_CONTINUE["$WORKER"]=0
  BRIDGE_AGENT_ISOLATION_MODE["$WORKER"]="linux-user"
  BRIDGE_AGENT_OS_USER["$WORKER"]="$(id -un)"
  BRIDGE_AGENT_CHANNELS["$WORKER"]="plugin:teams"

  # access.json is required by the file-check before the LISTEN probe runs.
  : >"$TEAMS_DIR/access.json"
}

write_teams_env() {
  local port="$1"
  cat >"$TEAMS_ENV" <<EOF
TEAMS_APP_ID=appid-value
TEAMS_APP_PASSWORD=apppass-value
TEAMS_WEBHOOK_PORT=$port
EOF
}

start_python_listener() {
  # Start a python listener that prints its port to stdout, then sleeps.
  # The fixture reads the port on the first line and keeps the process
  # alive for the duration of the smoke. The listener binds to 127.0.0.1
  # only so it does not contend with system services or trigger firewall
  # prompts on macOS.
  local fifo="$SMOKE_TMP_ROOT/listener.port"
  : >"$fifo"
  python3 - "$fifo" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
path = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
with open(path, "w") as f:
    f.write(str(s.getsockname()[1]))
# Hold the LISTEN socket open. 600s is well over the smoke runtime
# budget; the fixture kills us in cleanup.
time.sleep(600)
PY
  LISTENER_PID=$!
  # Poll for the port file with a short timeout to avoid races on slow
  # CI hosts. 5 seconds is generous — python startup is normally well
  # under a second.
  local waited=0
  while (( waited < 50 )); do
    if [[ -s "$fifo" ]]; then
      LISTENER_PORT="$(cat "$fifo")"
      break
    fi
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  if [[ -z "$LISTENER_PORT" ]]; then
    smoke_fail "python LISTEN fixture failed to bind within timeout"
  fi
  # Verify ss/lsof actually sees the bound port — confirms the fixture
  # is sound on this host before we trust assertions built on it.
  if ! bridge_port_is_listening "$LISTENER_PORT"; then
    smoke_fail "fixture sanity: bridge_port_is_listening returned 1 for verified-bound port $LISTENER_PORT"
  fi
}

assert_port_helper_rejects_nonsense() {
  if bridge_port_is_listening "" 2>/dev/null; then
    smoke_fail "bridge_port_is_listening should reject empty input"
  fi
  if bridge_port_is_listening "abc" 2>/dev/null; then
    smoke_fail "bridge_port_is_listening should reject non-numeric input"
  fi
}

assert_port_helper_on_free_port() {
  # Pick a port that almost certainly is not bound. Range is the agent
  # bridge plugin range; we walk up looking for a free port using the
  # existing bridge_port_is_free helper.
  local probe
  for probe in 39850 39851 39852 39853 39854 39855; do
    if bridge_port_is_free "$probe"; then
      if bridge_port_is_listening "$probe"; then
        smoke_fail "bridge_port_is_listening returned 0 for known-free port $probe"
      fi
      return 0
    fi
  done
  smoke_log "skip: no free port in 39850-39855 range to test against"
}

assert_runtime_ready_when_listener_bound() {
  write_teams_env "$LISTENER_PORT"
  if ! bridge_agent_channel_runtime_ready_for_item "$WORKER" "plugin:teams"; then
    smoke_fail "expected runtime_ready=true when teams listener is bound on port $LISTENER_PORT"
  fi
}

assert_runtime_not_ready_when_listener_absent() {
  # Switch the env to a port we have confirmed is NOT bound. We pick
  # the first free port in the plugin range so the assertion is robust
  # against whatever happens to be running on the test host.
  local free_port=""
  local probe
  for probe in 39860 39861 39862 39863 39864 39865; do
    if bridge_port_is_free "$probe"; then
      free_port="$probe"
      break
    fi
  done
  if [[ -z "$free_port" ]]; then
    smoke_log "skip: could not find a free port in 39860-39865 range"
    return 0
  fi
  write_teams_env "$free_port"
  if bridge_agent_channel_runtime_ready_for_item "$WORKER" "plugin:teams"; then
    smoke_fail "expected runtime_ready=false when teams .env points at unbound port $free_port"
  fi
}

assert_runtime_ready_when_port_key_absent() {
  # Backward-compatibility: an existing .env that has no TEAMS_WEBHOOK_PORT
  # line at all must still pass once the file-check passes — the LISTEN
  # probe is additive, not mandatory. bridge_read_port_from_env_file
  # returns empty stdout for a missing key.
  cat >"$TEAMS_ENV" <<EOF
TEAMS_APP_ID=appid-value
TEAMS_APP_PASSWORD=apppass-value
EOF
  if ! bridge_agent_channel_runtime_ready_for_item "$WORKER" "plugin:teams"; then
    smoke_fail "expected runtime_ready=true when teams .env has no TEAMS_WEBHOOK_PORT (legacy roster)"
  fi
}

assert_latency_budget() {
  # The fix must not blow the <500ms agent-bridge show latency budget.
  # We measure the runtime-ready call directly (the per-channel cost)
  # and require it well under 500ms. We give the budget 200ms here so
  # there is headroom for the rest of the show pipeline.
  write_teams_env "$LISTENER_PORT"
  local start_ns end_ns elapsed_ms
  if command -v python3 >/dev/null 2>&1; then
    start_ns="$(python3 -c 'import time; print(int(time.time()*1000))')"
    bridge_agent_channel_runtime_ready_for_item "$WORKER" "plugin:teams" >/dev/null || true
    end_ns="$(python3 -c 'import time; print(int(time.time()*1000))')"
    elapsed_ms=$(( end_ns - start_ns ))
    if (( elapsed_ms > 200 )); then
      smoke_fail "runtime_ready_for_item with LISTEN probe took ${elapsed_ms}ms; expected < 200ms"
    fi
    smoke_log "latency: ${elapsed_ms}ms (budget 200ms)"
  fi
}

main() {
  smoke_require_cmd python3
  # The smoke is portable to Linux + macOS. On a stripped host with neither
  # ss nor lsof, the helper fail-opens — assertions would not be meaningful
  # there, so skip cleanly.
  if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
    smoke_log "skipping: no LISTEN-probe tool (ss or lsof) available"
    exit 0
  fi

  smoke_setup_bridge_home "channel-runtime-listen-probe"
  source_bridge_lib
  register_worker
  start_python_listener

  smoke_run "bridge_port_is_listening rejects empty/non-numeric input"   assert_port_helper_rejects_nonsense
  smoke_run "bridge_port_is_listening returns 1 for a known-free port"   assert_port_helper_on_free_port
  smoke_run "runtime_ready=true when teams listener is bound"            assert_runtime_ready_when_listener_bound
  smoke_run "runtime_ready=false when teams .env port is not bound"      assert_runtime_not_ready_when_listener_absent
  smoke_run "runtime_ready=true when teams .env has no port key"         assert_runtime_ready_when_port_key_absent
  smoke_run "per-item LISTEN probe stays within latency budget"          assert_latency_budget
  smoke_log "passed"
}

main "$@"
