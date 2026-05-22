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

# True if `pid` is alive AND its command line is the A2A receiver for
# THIS install — i.e. a `bridge-handoffd.py serve` process launched with
# `--pidfile <pid_file>`. A bare `kill -0` is not enough: after the real
# receiver dies, PID reuse can hand that number to an unrelated live
# process (issue #1043 review r1). Matching only `bridge-handoffd.py` +
# `serve` is also not enough: another Agent Bridge install / config runs
# the same binary, so a stale pid file pointing at *that* install's
# receiver would still read as "running" here (review r2). The receiver
# is launched as `bridge-handoffd.py serve --config <config>
# --detach --pidfile <pid_file>`, and the pidfile path is unique per
# `$BRIDGE_HOME`, so requiring the exact `--pidfile <pid_file>` token in
# the cmdline ties the process to the exact pidfile being read.
# `ps -p <pid> -o command=` is portable across macOS and Linux.
#
# Args: $1 = pid, $2 = expected pidfile path the process must reference.
bridge_a2a_receiver_pid_is_receiver() {
  local pid="$1" expect_pid_file="$2" cmd
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$expect_pid_file" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmd" == *bridge-handoffd.py* && "$cmd" == *serve* ]] || return 1
  # Bind the match to this install: the running cmdline must carry the
  # exact `--pidfile` value of the pid file we just read.
  [[ "$cmd" == *"--pidfile $expect_pid_file"* ]]
}

# True if a receiver daemon is running: pid file present, the pid is
# alive, AND that pid is genuinely THIS install's A2A receiver process
# (not a coincidental PID-reuse match, nor another install's receiver).
bridge_a2a_receiver_running() {
  local pid_file pid
  pid_file="$(bridge_a2a_pid_file)"
  [[ -f "$pid_file" ]] || return 1
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  bridge_a2a_receiver_pid_is_receiver "$pid" "$pid_file"
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

  # Stale pid file from a previous (now-dead) receiver would otherwise let
  # the new launch's success check pass against the old pid.
  rm -f "$pid_file"

  # `serve --detach` double-forks into its own session AFTER the socket
  # bind, so the receiver is reparented out of this shell's process group
  # and survives the launching (managed agent) shell exiting. A bare
  # `nohup ... &` did not detach from the process group, so the listener
  # could be torn down with the tool session — issue #1043. The detached
  # grandchild owns the pid file, so the recorded pid is the durable
  # listener rather than a transient launcher pid.
  #
  # `--pidfile` is placed before `--config` so the per-install unique key
  # that bridge_a2a_receiver_pid_is_receiver() matches on appears early in
  # the cmdline, ahead of the (potentially long) config path, in case
  # `ps -o command=` truncates very long command lines.
  nohup python3 "$repo_root/bridge-handoffd.py" serve \
    --pidfile "$pid_file" --detach --config "$config" \
    >>"$log_file" 2>&1 &
  local launcher_pid=$!
  # The launcher process exits 0 once the detached child is running; if the
  # bind failed closed, it exits non-zero before any detach. Guard the wait
  # so a non-zero exit does not trip the caller's `set -e`.
  local launcher_rc=0
  wait "$launcher_pid" || launcher_rc=$?
  if (( launcher_rc != 0 )); then
    rm -f "$pid_file"
    echo "[a2a][error] receiver failed to start (exit $launcher_rc); see $log_file" >&2
    return 1
  fi

  # Wait for the detached child to publish its pid, then verify the pid is
  # genuinely the A2A receiver process — confirms a durable listener, not a
  # false success against a coincidental pid.
  local waited=0 pid=""
  while (( waited < 10 )); do
    if [[ -f "$pid_file" ]]; then
      pid="$(cat "$pid_file" 2>/dev/null || true)"
      if bridge_a2a_receiver_pid_is_receiver "$pid" "$pid_file"; then
        break
      fi
    fi
    sleep 1
    waited=$((waited + 1))
    pid=""
  done
  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    echo "[a2a][error] receiver did not come up durably; see $log_file" >&2
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
