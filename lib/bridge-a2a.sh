#!/usr/bin/env bash
# shellcheck shell=bash
# lib/bridge-a2a.sh — A2A cross-bridge handoff lifecycle helpers.
#
# Sourced by bridge-handoff-daemon.sh. Keeps the receiver-daemon
# start/stop/status + delivery-runner tick logic out of the root script
# per the repo convention (new logic lives in lib/bridge-*.sh helpers).
#
# The A2A receiver (`bridge-handoffd.py`) and the sender delivery runner
# (`bridge-a2a.py deliver`) are both managed here. The receiver is a
# long-lived process tracked by a pid file; the delivery runner is a
# short-lived drain invoked per tick (daemon-driven or cron-driven).

# Resolve the source-checkout root that holds the python entry points.
bridge_a2a_repo_root() {
  if [[ -n "${BRIDGE_A2A_REPO_ROOT:-}" ]]; then
    printf '%s' "$BRIDGE_A2A_REPO_ROOT"
    return 0
  fi
  # lib/bridge-a2a.sh -> repo root is the parent of lib/.
  local lib_dir
  lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  printf '%s' "$(cd -P "$lib_dir/.." && pwd -P)"
}

bridge_a2a_state_dir() {
  printf '%s' "${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
}

bridge_a2a_handoff_dir() {
  printf '%s' "$(bridge_a2a_state_dir)/handoff"
}

bridge_a2a_config_path() {
  if [[ -n "${BRIDGE_A2A_CONFIG:-}" ]]; then
    printf '%s' "$BRIDGE_A2A_CONFIG"
    return 0
  fi
  printf '%s' "${BRIDGE_HOME:-$HOME/.agent-bridge}/handoff.local.json"
}

bridge_a2a_pid_file() {
  printf '%s' "$(bridge_a2a_handoff_dir)/handoffd.pid"
}

bridge_a2a_log_file() {
  printf '%s' "${BRIDGE_LOG_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/logs}/a2a-handoffd.log"
}

# True if a receiver daemon is running (pid file present + process alive).
bridge_a2a_receiver_running() {
  local pid_file pid
  pid_file="$(bridge_a2a_pid_file)"
  [[ -f "$pid_file" ]] || return 1
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

bridge_a2a_receiver_pid() {
  local pid_file
  pid_file="$(bridge_a2a_pid_file)"
  [[ -f "$pid_file" ]] && cat "$pid_file" 2>/dev/null || true
}

# Start the receiver daemon in the background. Fails closed: the python
# entry point validates the tailnet bind and exits non-zero before this
# helper records a pid.
bridge_a2a_receiver_start() {
  local repo_root config pid_file log_file
  repo_root="$(bridge_a2a_repo_root)"
  config="$(bridge_a2a_config_path)"
  pid_file="$(bridge_a2a_pid_file)"
  log_file="$(bridge_a2a_log_file)"

  if bridge_a2a_receiver_running; then
    echo "[a2a] receiver already running (pid $(bridge_a2a_receiver_pid))"
    return 0
  fi
  if [[ ! -f "$config" ]]; then
    echo "[a2a][error] config not found: $config" >&2
    echo "[a2a]        copy handoff.local.example.json -> $config (chmod 0600)" >&2
    return 1
  fi

  mkdir -p "$(bridge_a2a_handoff_dir)" "$(dirname "$log_file")"

  # Preflight the bind synchronously so a fail-closed startup surfaces a
  # clear error instead of a daemon that exits silently in the background.
  if ! python3 "$repo_root/bridge-handoffd.py" preflight --config "$config"; then
    echo "[a2a][error] preflight failed; receiver not started" >&2
    return 1
  fi

  nohup python3 "$repo_root/bridge-handoffd.py" serve --config "$config" \
    >>"$log_file" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >"$pid_file"
  # Give the process a beat to fail-closed on bind; if it died, report it.
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    echo "[a2a][error] receiver exited immediately; see $log_file" >&2
    return 1
  fi
  echo "[a2a] receiver started (pid $pid); log: $log_file"
  return 0
}

bridge_a2a_receiver_stop() {
  local pid_file pid
  pid_file="$(bridge_a2a_pid_file)"
  if ! bridge_a2a_receiver_running; then
    rm -f "$pid_file" 2>/dev/null || true
    echo "[a2a] receiver not running"
    return 0
  fi
  pid="$(bridge_a2a_receiver_pid)"
  kill "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do
    sleep 1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$pid_file" 2>/dev/null || true
  echo "[a2a] receiver stopped (pid $pid)"
  return 0
}

# Run one delivery-runner drain pass (short-lived).
bridge_a2a_deliver_tick() {
  local repo_root config
  repo_root="$(bridge_a2a_repo_root)"
  config="$(bridge_a2a_config_path)"
  if [[ ! -f "$config" ]]; then
    echo "[a2a][error] config not found: $config" >&2
    return 1
  fi
  python3 "$repo_root/bridge-a2a.py" deliver "$@"
}

bridge_a2a_status() {
  local config
  config="$(bridge_a2a_config_path)"
  echo "config        : $config $( [[ -f "$config" ]] && printf '(present)' || printf '(MISSING)')"
  echo "handoff_dir   : $(bridge_a2a_handoff_dir)"
  echo "pid_file      : $(bridge_a2a_pid_file)"
  if bridge_a2a_receiver_running; then
    echo "receiver      : running (pid $(bridge_a2a_receiver_pid))"
  else
    echo "receiver      : stopped"
  fi
  echo "log           : $(bridge_a2a_log_file)"
}
