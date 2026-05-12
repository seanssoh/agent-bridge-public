#!/usr/bin/env bash
# scripts/smoke/alive-multi-signal.sh — Issue #780 smoke.
#
# Validates the new multi-signal `alive` field on
# `agent-bridge show <agent> --json`. The field is an OR of three
# signals; any one being live → alive=true. This smoke exercises each
# signal in isolation plus the all-dead baseline:
#
#   T1. tmux-only           → alive=true, signals.tmux=true
#   T2. pid-only            → alive=true, signals.pid=true
#   T3. channel-LISTEN only → alive=true, signals.channel=true
#   T4. nothing active      → alive=false, all signals=false
#
# Uses an isolated BRIDGE_HOME via smoke_setup_bridge_home — never
# touches the operator's live runtime. tmux + channel signals are
# faked via roster-level shell overrides (same trick that
# agent-retire.sh uses to fake `bridge_agent_is_active`), so the smoke
# needs no real tmux server, no real channel plugin, and no
# privileged listener.

set -euo pipefail

SMOKE_NAME="alive-multi-signal"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

LISTENER_PID=""
LISTENER_PORT=""

cleanup() {
  if [[ -n "$LISTENER_PID" ]] && kill -0 "$LISTENER_PID" 2>/dev/null; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "alive-multi-signal"

REPO_ROOT="$SMOKE_REPO_ROOT"

BASH4_BIN="${BASH:-bash}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

agent_show_json() {
  local agent="$1"
  "$BASH4_BIN" "$REPO_ROOT/bridge-agent.sh" show "$agent" --json
}

# Pluck a JSON path out of show output via python (jq may not be
# installed on every smoke host).
jget() {
  local payload="$1"
  local path="$2"
  "$PY_BIN" - "$payload" "$path" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
path = sys.argv[2]
cur = doc
for part in path.split("."):
    if part == "":
        continue
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        cur = None
        break
if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("null")
else:
    print(cur)
PY
}

# Roster writer — single static agent + a hook block that overrides
# the alive helpers we want to mock. The hook block is appended after
# the agent registration so it always wins. `keep_*` flags decide
# which signals the hooks force to true.
write_roster() {
  local agent="$1"
  local force_tmux="$2"     # 0|1
  local fake_port="$3"      # empty | port number for channel mock

  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "$agent"
BRIDGE_AGENT_ENGINE["$agent"]="claude"
BRIDGE_AGENT_SESSION["$agent"]="$agent"
BRIDGE_AGENT_WORKDIR["$agent"]="$BRIDGE_AGENT_HOME_ROOT/$agent"
EOF

  if [[ "$force_tmux" == "1" ]]; then
    cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

# T1: pretend tmux session is alive without booting a real one.
bridge_agent_is_active() {
  if [[ "\$1" == "$agent" ]]; then
    return 0
  fi
  return 1
}
EOF
  else
    cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

# Force tmux-signal false so other cases isolate the remaining
# signals. The default helper returns false anyway in an isolated
# BRIDGE_HOME (no tmux session), but override explicitly so the
# smoke is robust to a stray live tmux server on the build host.
bridge_agent_is_active() {
  return 1
}
EOF
  fi

  if [[ -n "$fake_port" ]]; then
    cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

# T3: surface a single fake plugin port so the channel-LISTEN signal
# can be exercised without a real teams .env or plugin process. The
# alive helper iterates this output and runs an actual socket probe
# against the port the smoke harness opens.
bridge_agent_plugin_ports() {
  printf '%s\t%s\t%s\n' "$fake_port" "smoke-listener" "smoke"
}
EOF
  fi
}

# Spin up a TCP listener on a free port; export the port so the
# roster can advertise it. We use Python so we don't depend on
# `nc -l` flavor differences across macOS/Linux/BusyBox.
start_listener() {
  local port_file
  port_file="$SMOKE_TMP_ROOT/listener.port"
  rm -f "$port_file"
  "$PY_BIN" - "$port_file" <<'PY' &
import socket
import sys
import time

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(8)
    port = sock.getsockname()[1]
    with open(sys.argv[1], "w") as fh:
        fh.write(str(port))
    # Accept loop — keep listening until the parent kills us. We
    # close each accepted socket immediately; the probe only checks
    # that connect() succeeds.
    sock.settimeout(0.5)
    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline:
        try:
            client, _ = sock.accept()
        except socket.timeout:
            continue
        try:
            client.close()
        except OSError:
            pass
PY
  LISTENER_PID=$!
  # Wait up to ~2s for the port file to appear.
  local attempts=0
  while (( attempts < 40 )); do
    if [[ -f "$port_file" ]]; then
      LISTENER_PORT="$(cat "$port_file")"
      [[ -n "$LISTENER_PORT" ]] && return 0
    fi
    sleep 0.05
    attempts=$((attempts + 1))
  done
  smoke_fail "listener failed to publish its port within 2s"
}

stop_listener() {
  if [[ -n "$LISTENER_PID" ]] && kill -0 "$LISTENER_PID" 2>/dev/null; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  LISTENER_PID=""
  LISTENER_PORT=""
}

# Materialize <agent_home>/runtime/agent.pid with the given pid. The
# alive helper resolves home via bridge_agent_default_home, which under
# the v2 layout returns $BRIDGE_AGENT_ROOT_V2/<agent>/home (see
# scripts/smoke/lib.sh — BRIDGE_LAYOUT is forced to v2).
write_agent_pid_file() {
  local agent="$1"
  local pid="$2"
  local home="$BRIDGE_AGENT_ROOT_V2/$agent/home"
  mkdir -p "$home/runtime"
  printf '%s\n' "$pid" >"$home/runtime/agent.pid"
}

clear_agent_pid_file() {
  local agent="$1"
  local home="$BRIDGE_AGENT_ROOT_V2/$agent/home"
  rm -f "$home/runtime/agent.pid"
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

test_tmux_only() {
  local agent="alpha"
  clear_agent_pid_file "$agent"
  write_roster "$agent" 1 ""

  local payload
  payload="$(agent_show_json "$agent")"
  smoke_assert_eq "true"  "$(jget "$payload" "alive")"                  "T1 alive"
  smoke_assert_eq "true"  "$(jget "$payload" "alive_signals.tmux")"     "T1 signals.tmux"
  smoke_assert_eq "false" "$(jget "$payload" "alive_signals.pid")"      "T1 signals.pid"
  smoke_assert_eq "false" "$(jget "$payload" "alive_signals.channel")"  "T1 signals.channel"
}

test_pid_only() {
  local agent="alpha"
  write_agent_pid_file "$agent" "$$"
  write_roster "$agent" 0 ""

  local payload
  payload="$(agent_show_json "$agent")"
  smoke_assert_eq "true"  "$(jget "$payload" "alive")"                  "T2 alive"
  smoke_assert_eq "false" "$(jget "$payload" "alive_signals.tmux")"     "T2 signals.tmux"
  smoke_assert_eq "true"  "$(jget "$payload" "alive_signals.pid")"      "T2 signals.pid"
  smoke_assert_eq "false" "$(jget "$payload" "alive_signals.channel")"  "T2 signals.channel"
  clear_agent_pid_file "$agent"
}

test_listen_only() {
  local agent="alpha"
  clear_agent_pid_file "$agent"
  start_listener
  write_roster "$agent" 0 "$LISTENER_PORT"

  local payload
  payload="$(agent_show_json "$agent")"
  smoke_assert_eq "true"  "$(jget "$payload" "alive")"                  "T3 alive"
  smoke_assert_eq "false" "$(jget "$payload" "alive_signals.tmux")"     "T3 signals.tmux"
  smoke_assert_eq "false" "$(jget "$payload" "alive_signals.pid")"      "T3 signals.pid"
  smoke_assert_eq "true"  "$(jget "$payload" "alive_signals.channel")"  "T3 signals.channel"
  stop_listener
}

test_nothing_active() {
  local agent="alpha"
  clear_agent_pid_file "$agent"
  stop_listener
  write_roster "$agent" 0 ""

  local payload
  payload="$(agent_show_json "$agent")"
  smoke_assert_eq "false" "$(jget "$payload" "alive")"                  "T4 alive"
  smoke_assert_eq "false" "$(jget "$payload" "alive_signals.tmux")"     "T4 signals.tmux"
  smoke_assert_eq "false" "$(jget "$payload" "alive_signals.pid")"      "T4 signals.pid"
  smoke_assert_eq "false" "$(jget "$payload" "alive_signals.channel")"  "T4 signals.channel"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

smoke_run "T1 tmux-only"           test_tmux_only
smoke_run "T2 pid-only"            test_pid_only
smoke_run "T3 channel-LISTEN only" test_listen_only
smoke_run "T4 nothing active"      test_nothing_active

smoke_log "all cases passed"
