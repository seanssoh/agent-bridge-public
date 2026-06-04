#!/usr/bin/env bash
# bridge-daemon-liveness.sh — issue #265 proposal D
#
# OS-level liveness watcher for the Agent Bridge daemon. Designed to run
# OUTSIDE the daemon process tree (under launchd on macOS or systemd .timer
# on Linux) so a hung daemon main loop cannot prevent the watcher from
# observing it.
#
# Behavior:
#   1. Read mtime of $BRIDGE_STATE_DIR/daemon.heartbeat (touched by
#      bridge-daemon.sh::cmd_run on every BRIDGE_DAEMON_HEARTBEAT_SECONDS
#      tick — see commit that added the printf next to bridge_audit_log
#      daemon_tick).
#   2. If the file does not exist, do nothing — fresh install or daemon
#      not yet started; let the daemon's normal start path establish the
#      baseline.
#   3. If mtime is younger than BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS
#      (default 600s = 10 min), do nothing.
#   4. If stale AND the daemon pid is recorded AND alive, AND the cooldown
#      since the last restart attempt has elapsed, run
#      `bridge-daemon.sh stop --force && bridge-daemon.sh start`. Cooldown prevents
#      a broken daemon from triggering a restart-loop every minute.
#   5. If stale but the daemon is not running, do nothing — the normal
#      start path (launchd KeepAlive / systemd Restart=always) will bring
#      it back; the liveness watcher only addresses the silent-hang case
#      where the process is alive but the loop has frozen.
#
# Audit:
#   Writes one of `daemon_liveness_ok`, `daemon_liveness_skip_no_baseline`,
#   `daemon_liveness_skip_not_running`, `daemon_liveness_skip_cooldown`,
#   `daemon_liveness_restart_attempt`, or `daemon_liveness_restart_failed`
#   to $BRIDGE_AUDIT_LOG when bridge-audit.py is invokable. Failures to
#   write audit are non-fatal — the watcher's job is restarting, not
#   logging.
#
# Environment:
#   BRIDGE_HOME                                  default $HOME/.agent-bridge
#   BRIDGE_STATE_DIR                             default $BRIDGE_HOME/state
#   BRIDGE_AUDIT_LOG                             default $BRIDGE_HOME/logs/audit.jsonl
#   BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS     default 600
#   BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS      default 600
#   BRIDGE_DAEMON_HEARTBEAT_FILE                 default $BRIDGE_STATE_DIR/daemon.heartbeat
#   BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE         default $BRIDGE_STATE_DIR/daemon-liveness-cooldown.ts
#   BRIDGE_DAEMON_LIVENESS_DRY_RUN               set to 1 to log the decision but skip the actual stop/start

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
: "${BRIDGE_STATE_DIR:=$BRIDGE_HOME/state}"
: "${BRIDGE_AUDIT_LOG:=$BRIDGE_HOME/logs/audit.jsonl}"
: "${BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS:=600}"
: "${BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS:=600}"
: "${BRIDGE_DAEMON_HEARTBEAT_FILE:=$BRIDGE_STATE_DIR/daemon.heartbeat}"
: "${BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE:=$BRIDGE_STATE_DIR/daemon-liveness-cooldown.ts}"
: "${BRIDGE_DAEMON_LIVENESS_DRY_RUN:=0}"

# Sanitize numeric envs — fall back to defaults on garbage so a typo in a
# launchd EnvironmentVariables block can't disable the watcher.
[[ "$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]] || BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS=600
[[ "$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]]  || BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS=600

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
DAEMON_PID_FILE="${BRIDGE_DAEMON_PID_FILE:-$BRIDGE_STATE_DIR/daemon.pid}"

now_ts() { date +%s; }

file_mtime() {
  # macOS / BSD: stat -f %m. Linux / GNU coreutils: stat -c %Y.
  local f="$1"
  local mtime
  if mtime="$(stat -f %m "$f" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi
  if mtime="$(stat -c %Y "$f" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi
  return 1
}

emit_audit() {
  # Best-effort JSON-line audit. We deliberately do not source bridge-lib.sh
  # (heavy: pulls in tmux/queue/state modules) just for one log line — the
  # python script is small and standalone.
  local action="$1"
  shift || true
  local audit_py="$REPO_ROOT/bridge-audit.py"
  [[ -x "$audit_py" || -f "$audit_py" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$BRIDGE_AUDIT_LOG")" 2>/dev/null || true
  python3 "$audit_py" write \
    --file "$BRIDGE_AUDIT_LOG" \
    --actor daemon_liveness \
    --action "$action" \
    --target daemon \
    "$@" >/dev/null 2>&1 || true
}

daemon_pid_alive() {
  local pid
  [[ -f "$DAEMON_PID_FILE" ]] || return 1
  pid="$(head -n1 "$DAEMON_PID_FILE" 2>/dev/null | tr -d '[:space:]')"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

cooldown_active() {
  # Returns 0 (true) when last restart attempt is within cooldown window.
  local last_ts now
  [[ -f "$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE" ]] || return 1
  last_ts="$(tr -d '[:space:]' <"$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE" 2>/dev/null)"
  [[ "$last_ts" =~ ^[0-9]+$ ]] || return 1
  now="$(now_ts)"
  (( now - last_ts < BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS ))
}

record_cooldown() {
  mkdir -p "$(dirname "$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE")" 2>/dev/null || true
  printf '%s\n' "$(now_ts)" 2>/dev/null >"$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE" || true
}

restart_daemon() {
  local pid="$1"
  local age="$2"
  emit_audit daemon_liveness_restart_attempt \
    --detail pid="$pid" \
    --detail heartbeat_age_seconds="$age" \
    --detail threshold_seconds="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
  record_cooldown
  if [[ "$BRIDGE_DAEMON_LIVENESS_DRY_RUN" == "1" ]]; then
    printf '[liveness] DRY_RUN — would restart daemon pid=%s age=%ss\n' "$pid" "$age"
    return 0
  fi
  # Use BRIDGE_HOME's daemon script so the watcher targets the same install
  # root the heartbeat file was observed in. The launchd plist sets
  # BRIDGE_HOME explicitly; override via env if running by hand.
  #
  # Issue #1463: route through the single `restart` verb instead of a
  # direct `stop --force` + `start`. On macOS launchd installs `restart`
  # cycles launchd's OWN supervised job (`launchctl kickstart -k`) so the
  # fresh daemon is launchd's instance and holds the singleton lock inside
  # the supervised process tree — KeepAlive then has nothing to thrash
  # against. A direct out-of-band stop+start (the old code) established a
  # NON-launchd lock holder and re-armed the KeepAlive vs lock thrash on
  # every ~600s liveness restart. On Linux (systemd/nohup) `restart` falls
  # through to the same stop+start it always did, so this is a no-op there.
  # rc=2 means restart REFUSED (out-of-band split needs a one-time operator
  # reconcile) — surface it distinctly rather than masking it as success.
  #
  # --force: the liveness watchdog only fires on a wedged daemon (heartbeat
  # past threshold). Bypass the #314/#315 active-agent guard so a stuck
  # daemon can still be restarted on a host with running agents.
  local restart_rc=0
  bash "$DAEMON_SH" restart --force >/dev/null 2>&1 || restart_rc=$?
  if (( restart_rc == 2 )); then
    emit_audit daemon_liveness_restart_refused \
      --detail reason="launchd_out_of_band_split" \
      --detail heartbeat_age_seconds="$age"
    printf '[liveness] restart REFUSED (out-of-band launchd split) — run "bridge-daemon.sh stop --force" once to reconcile\n'
    return 1
  fi
  if (( restart_rc != 0 )); then
    emit_audit daemon_liveness_restart_failed \
      --detail restart_rc="$restart_rc"
    return 1
  fi
  printf '[liveness] restarted daemon pid=%s age=%ss\n' "$pid" "$age"
  return 0
}

main() {
  local mtime now age pid

  if [[ ! -f "$BRIDGE_DAEMON_HEARTBEAT_FILE" ]]; then
    emit_audit daemon_liveness_skip_no_baseline \
      --detail heartbeat_file="$BRIDGE_DAEMON_HEARTBEAT_FILE"
    return 0
  fi

  if ! mtime="$(file_mtime "$BRIDGE_DAEMON_HEARTBEAT_FILE")"; then
    emit_audit daemon_liveness_skip_no_baseline \
      --detail heartbeat_file="$BRIDGE_DAEMON_HEARTBEAT_FILE" \
      --detail reason="stat_failed"
    return 0
  fi

  now="$(now_ts)"
  age=$(( now - mtime ))

  if (( age < BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS )); then
    emit_audit daemon_liveness_ok \
      --detail heartbeat_age_seconds="$age" \
      --detail threshold_seconds="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
    return 0
  fi

  if ! pid="$(daemon_pid_alive)"; then
    # No live process to kill. launchd's KeepAlive / systemd's Restart=always
    # handles the "process gone" case; the liveness watcher exists for the
    # silent-hang case. Be conservative and stay out of the way.
    emit_audit daemon_liveness_skip_not_running \
      --detail heartbeat_age_seconds="$age" \
      --detail threshold_seconds="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
    return 0
  fi

  if cooldown_active; then
    emit_audit daemon_liveness_skip_cooldown \
      --detail pid="$pid" \
      --detail heartbeat_age_seconds="$age" \
      --detail cooldown_seconds="$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS"
    return 0
  fi

  restart_daemon "$pid" "$age"
}

main "$@"
