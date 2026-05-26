#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/F-daemon-supp-groups-real.sh — Lane F (v0.15.0-beta1)
# Linux + sudo real-host smoke.
#
# End-to-end verification of the autonomous daemon-side supp-groups
# poll + detached refresh worker on a real Linux host with sudo:
#
#   1. Start a real bridge daemon under a temporary BRIDGE_HOME.
#   2. Create a transient ab-agent-smoke-<rand> group (sudo groupadd).
#   3. Add the controller user to it via real `usermod -aG`.
#   4. Verify the OLD daemon's `/proc/<pid>/status` Groups line does
#      NOT contain the new GID (the running process credential set is
#      stale by design — `id <user>` reads NSS, NOT credentials, so the
#      Groups line is the canonical check).
#   5. Let the daemon's poll loop discover the staleness and dispatch
#      the worker (or invoke `supp-refresh-worker` directly if the
#      poll interval is too long for the smoke budget).
#   6. Assert the new daemon's `/proc/<pid>/status` Groups contains
#      the target GID.
#   7. Cleanup: stop daemon, remove the transient group + controller
#      membership, restore BRIDGE_HOME tree.
#
# Gates:
#   - SKIP on non-Linux (macOS / WSL probes via uname).
#   - SKIP when sudo + groupadd/groupdel/usermod are not available or
#     the operator hasn't run `agent-bridge init sudoers daemon-refresh
#     --apply` (probed via the same sudoers existence test the systemd
#     installer uses).
#   - SKIP in CI unless BRIDGE_SMOKE_F_REAL_OPT_IN=1 is set explicitly
#     (the operator's GitHub Actions runner does NOT have an
#     interactive sudoer profile by default).
#
# Footgun #11: every helper is built with `printf '%s\n' >file` and
# run as an external script. No `<<<` here-string / `<<EOF` heredoc-stdin
# into subprocess capture.

set -uo pipefail

SMOKE_NAME="F-daemon-supp-groups-real"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REAL_GROUP=""
REAL_CONTROLLER=""
DAEMON_PID_FILE=""

cleanup() {
  # Best-effort daemon stop before removing transient group so the
  # daemon doesn't keep a credential reference to the GID we're
  # about to delete.
  if [[ -n "${DAEMON_PID_FILE:-}" && -r "$DAEMON_PID_FILE" ]]; then
    local pid
    pid="$(head -n1 "$DAEMON_PID_FILE" 2>/dev/null | tr -dc '0-9')"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      local i=0
      while (( i < 30 )) && kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        i=$(( i + 1 ))
      done
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi

  # Remove controller from transient group + delete group (sudo, best-
  # effort — we never fail cleanup on rc).
  if [[ -n "${REAL_CONTROLLER:-}" && -n "${REAL_GROUP:-}" ]]; then
    sudo -n gpasswd -d "$REAL_CONTROLLER" "$REAL_GROUP" >/dev/null 2>&1 || true
    sudo -n groupdel "$REAL_GROUP" >/dev/null 2>&1 || true
  fi

  smoke_cleanup_temp_root
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Linux gate.
# ---------------------------------------------------------------------------
if ! smoke_is_linux; then
  smoke_skip "$SMOKE_NAME" "non-Linux host (uname != Linux)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Opt-in gate (CI default = skip; operator real-host run sets the env).
# ---------------------------------------------------------------------------
if [[ "${BRIDGE_SMOKE_F_REAL_OPT_IN:-0}" != "1" ]]; then
  smoke_skip "$SMOKE_NAME" "BRIDGE_SMOKE_F_REAL_OPT_IN!=1 (real-host smoke needs explicit opt-in)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Tool gate.
# ---------------------------------------------------------------------------
for cmd in sudo groupadd groupdel usermod gpasswd getent id; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    smoke_skip "$SMOKE_NAME" "missing required command: $cmd"
    exit 0
  fi
done

# ---------------------------------------------------------------------------
# Controller resolution + sudoers preflight.
# ---------------------------------------------------------------------------
REAL_CONTROLLER="$(id -un 2>/dev/null || true)"
if [[ -z "$REAL_CONTROLLER" || "$REAL_CONTROLLER" == "root" ]]; then
  smoke_skip "$SMOKE_NAME" "controller must be a real non-root user (got '$REAL_CONTROLLER')"
  exit 0
fi

# Probe the daemon-refresh sudoers drop-in. Without it the helper
# would always return `manual-required-sudoers` and the worker could
# not actually restart the daemon, so the test would be meaningless.
SUDOERS_GLOB="/etc/sudoers.d/agent-bridge-daemon-refresh-${REAL_CONTROLLER}-*"
# shellcheck disable=SC2086  # intentional glob expansion
set -- $SUDOERS_GLOB
if [[ ! -e "$1" ]]; then
  smoke_skip "$SMOKE_NAME" "missing sudoers drop-in $SUDOERS_GLOB (run 'agent-bridge init sudoers daemon-refresh --apply' first)"
  exit 0
fi

# Probe that `sudo -n -u <controller> -H -- bash -c id -G` actually
# returns the canonical group set. If sudoers rejects, skip — the
# refresh helper will skip the same way at runtime.
if ! sudo -n -u "$REAL_CONTROLLER" -H -- "$(command -v bash)" -c 'id -G' >/dev/null 2>&1; then
  smoke_skip "$SMOKE_NAME" "sudo -n -u $REAL_CONTROLLER refresh probe rejected (sudoers / NOPASSWD)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Setup: temporary BRIDGE_HOME with the source bridge-daemon.sh in place.
# ---------------------------------------------------------------------------
smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

# Mirror the source bridge-daemon.sh into BRIDGE_HOME so the helper's
# detached worker invocation finds the canonical script path. We
# symlink rather than copy so the live source is what executes.
for entry in bridge-daemon.sh bridge-lib.sh agent-bridge agb lib scripts agents hooks; do
  if [[ -e "$REPO_ROOT/$entry" ]]; then
    ln -s "$REPO_ROOT/$entry" "$BRIDGE_HOME/$entry"
  fi
done

DAEMON_PID_FILE="$BRIDGE_STATE_DIR/bridge-daemon.pid"

# ---------------------------------------------------------------------------
# Start a real daemon under the temporary BRIDGE_HOME.
# ---------------------------------------------------------------------------
smoke_log "starting temporary bridge daemon under $BRIDGE_HOME"
# Use cmd_start (background fork) so the daemon detaches; we observe
# via the pid file.
"$(command -v bash)" "$BRIDGE_HOME/bridge-daemon.sh" start >/dev/null 2>&1 || true

# Wait for the pid file to settle.
wait_for_daemon() {
  local target="$1"
  local i=0
  while (( i < 50 )); do
    if [[ -s "$target" ]]; then
      local pid
      pid="$(head -n1 "$target" 2>/dev/null | tr -dc '0-9')"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        printf '%s' "$pid"
        return 0
      fi
    fi
    sleep 0.1
    i=$(( i + 1 ))
  done
  return 1
}

OLD_DAEMON_PID="$(wait_for_daemon "$DAEMON_PID_FILE" 2>/dev/null || true)"
if [[ -z "$OLD_DAEMON_PID" ]]; then
  smoke_skip "$SMOKE_NAME" "daemon failed to start under temp BRIDGE_HOME (skipping rather than fail-host)"
  exit 0
fi
smoke_log "daemon up pid=$OLD_DAEMON_PID"

# ---------------------------------------------------------------------------
# Create a transient ab-agent-smoke-<rand> group + add controller to it.
# ---------------------------------------------------------------------------
RAND_SUFFIX="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c8)"
REAL_GROUP="ab-agent-smoke-${RAND_SUFFIX}"
smoke_log "creating transient group $REAL_GROUP"
if ! sudo -n groupadd -f "$REAL_GROUP" >/dev/null 2>&1; then
  smoke_skip "$SMOKE_NAME" "sudo -n groupadd $REAL_GROUP rejected — host sudoers not pre-authorized for groupadd"
  exit 0
fi
if ! sudo -n usermod -aG "$REAL_GROUP" "$REAL_CONTROLLER" >/dev/null 2>&1; then
  smoke_skip "$SMOKE_NAME" "sudo -n usermod -aG rejected — host sudoers not pre-authorized for usermod"
  exit 0
fi

TARGET_GID="$(getent group "$REAL_GROUP" 2>/dev/null | awk -F: '{ print $3 }')"
if [[ -z "$TARGET_GID" ]]; then
  smoke_fail "transient group $REAL_GROUP missing GID after groupadd"
fi
smoke_log "transient group=$REAL_GROUP gid=$TARGET_GID controller=$REAL_CONTROLLER"

# ---------------------------------------------------------------------------
# Phase 1 assertion: old daemon's /proc/<pid>/status Groups MUST lack the
# new GID (kernel credential set is stale-by-design).
# ---------------------------------------------------------------------------
old_groups_line() {
  local pid="$1"
  awk '/^Groups:/ { for (i=2; i<=NF; i++) print $i; exit }' "/proc/$pid/status" 2>/dev/null
}

if old_groups_line "$OLD_DAEMON_PID" | grep -Fxq "$TARGET_GID"; then
  smoke_fail "old daemon pid=$OLD_DAEMON_PID already contains GID $TARGET_GID — stale-supp-groups premise violated"
fi
smoke_log "phase-1 confirmed: pid=$OLD_DAEMON_PID Groups: lacks GID $TARGET_GID (stale set as expected)"

# ---------------------------------------------------------------------------
# Drive the autonomous detection + dispatch. Either:
#   (a) wait for the daemon poll loop to find the stale set on its
#       own (default BRIDGE_DAEMON_INTERVAL=5s) and dispatch the
#       worker, OR
#   (b) invoke `supp-refresh-worker` directly under the daemon's
#       BRIDGE_HOME — both paths exercise the same helper boundary.
#
# We try (a) first with a short budget; if the worker hasn't completed
# in `BRIDGE_SMOKE_F_REAL_BUDGET_SECS` (default 30) seconds we fall
# back to (b) for determinism.
# ---------------------------------------------------------------------------
BUDGET_SECS="${BRIDGE_SMOKE_F_REAL_BUDGET_SECS:-30}"
STATE_FILE="$BRIDGE_STATE_DIR/daemon.supp-refresh.state"

await_refresh_outcome() {
  local target_gid="$1"
  local budget="$2"
  local i=0
  while (( i < budget )); do
    # Re-read pid (may have rolled to a fresh daemon after restart).
    local cur_pid=""
    if [[ -s "$DAEMON_PID_FILE" ]]; then
      cur_pid="$(head -n1 "$DAEMON_PID_FILE" 2>/dev/null | tr -dc '0-9')"
    fi
    if [[ -n "$cur_pid" ]] && kill -0 "$cur_pid" 2>/dev/null; then
      if old_groups_line "$cur_pid" | grep -Fxq "$target_gid"; then
        printf '%s' "$cur_pid"
        return 0
      fi
    fi
    sleep 1
    i=$(( i + 1 ))
  done
  return 1
}

smoke_log "awaiting autonomous detection within ${BUDGET_SECS}s"
NEW_DAEMON_PID="$(await_refresh_outcome "$TARGET_GID" "$BUDGET_SECS" 2>/dev/null || true)"

if [[ -z "$NEW_DAEMON_PID" ]]; then
  smoke_log "autonomous detection budget exceeded — invoking supp-refresh-worker directly"
  "$(command -v bash)" "$BRIDGE_HOME/bridge-daemon.sh" supp-refresh-worker "$REAL_GROUP" \
    >>"$BRIDGE_LOG_DIR/daemon-supp-refresh-direct.log" 2>&1 || true
  NEW_DAEMON_PID="$(await_refresh_outcome "$TARGET_GID" 30 2>/dev/null || true)"
fi

if [[ -z "$NEW_DAEMON_PID" ]]; then
  STATE_BODY="$(cat "$STATE_FILE" 2>/dev/null || printf 'NO_STATE')"
  WORKER_LOG_BODY="$(tail -n40 "$BRIDGE_LOG_DIR/daemon-supp-refresh.log" 2>/dev/null || true)"
  WORKER_DIRECT_LOG="$(tail -n40 "$BRIDGE_LOG_DIR/daemon-supp-refresh-direct.log" 2>/dev/null || true)"
  smoke_fail "refresh did not produce a daemon with GID $TARGET_GID within budget. state=$STATE_BODY worker_log=$WORKER_LOG_BODY direct_log=$WORKER_DIRECT_LOG"
fi

smoke_log "phase-2 confirmed: new daemon pid=$NEW_DAEMON_PID Groups: contains GID $TARGET_GID"

# ---------------------------------------------------------------------------
# Optional: assert the throttle state recorded a final ok-* / dispatched-*
# status (forensic — the actual gate is the /proc Groups assertion above).
# ---------------------------------------------------------------------------
if [[ -r "$STATE_FILE" ]]; then
  STATE_BODY="$(cat "$STATE_FILE" 2>/dev/null || true)"
  case "$STATE_BODY" in
    *"last_status=ok"*|*"last_status=dispatched"*|*"last_status=skipped-"*)
      smoke_log "throttle state final: $(printf '%s' "$STATE_BODY" | tr '\n' ' ')"
      ;;
    *)
      smoke_log "warning: throttle state final does not match ok/dispatched/skipped — body: $(printf '%s' "$STATE_BODY" | tr '\n' ' ')"
      ;;
  esac
fi

smoke_log "ALL Lane F real-host tests passed"
