#!/usr/bin/env bash
# bridge-isolation-helpers.sh — small probes for running a snippet as the
# isolated UID of a linux-user-isolated agent via the existing sudoers
# allowlist (`bash` + `tmux` only — see bridge-migration.sh:773).
#
# Issue #832: channel-health probes need a way to read a dotenv file that the
# controller cannot `[[ -r ]]` but the agent's isolated UID can. Without this,
# the daemon collapses a controller-blind dotenv into a "miss" and fires a
# false channel_health_miss audit row.
#
# These helpers depend only on already-loaded helpers from `bridge-agents.sh`
# (sourced earlier in bridge-lib.sh): `bridge_agent_os_user`,
# `bridge_agent_linux_user_isolation_effective`, and `BRIDGE_BASH_BIN`. They
# do NOT source bridge-lib.sh inside the isolated UID — the inline script
# passed to `sudo -n -u <user> bash -c` is self-contained.

# bridge_isolation_can_sudo_to_agent <agent>
#
# Returns:
#   0 — agent is in linux-user isolation AND passwordless sudo to its os_user
#       succeeds.
#   1 — agent is not in linux-user isolation (caller should run directly as
#       the controller).
#   2 — agent IS isolated but `sudo -n -u <os_user> bash -c true` fails
#       (no passwordless sudoers rule).
#
# Non-fatal: never exits the shell, suppresses stderr unless
# BRIDGE_ISOLATION_HELPERS_DEBUG=1 is set.
bridge_isolation_can_sudo_to_agent() {
  local agent="$1"
  local os_user=""
  local bash_bin="${BRIDGE_BASH_BIN:-bash}"
  local debug="${BRIDGE_ISOLATION_HELPERS_DEBUG:-0}"

  [[ -n "$agent" ]] || return 1

  # Not isolated — caller should run directly.
  if ! bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    return 1
  fi

  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
  [[ -n "$os_user" ]] || return 1

  if ! command -v sudo >/dev/null 2>&1; then
    return 2
  fi

  if [[ "$debug" == "1" ]]; then
    sudo -n -u "$os_user" "$bash_bin" -c 'exit 0' && return 0 || return 2
  fi
  if sudo -n -u "$os_user" "$bash_bin" -c 'exit 0' 2>/dev/null; then
    return 0
  fi
  return 2
}

# bridge_isolation_run_as_agent_user_via_bash <agent> <script> [arg...]
#
# Runs the inline bash script as the agent's isolated UID via:
#   sudo -n -u <os_user> ${BRIDGE_BASH_BIN:-bash} -c "$script" bridge-isolation "$@"
#
# The fixed "bridge-isolation" argument becomes "$0" inside the inline
# script; user-supplied positional args are bound as "$1", "$2", ...
#
# Returns (distinct ranges):
#   0   — agent isolated, sudo OK, script returned 0
#   1   — agent NOT in linux-user isolation (caller should run directly)
#   2   — agent isolated but passwordless sudo unavailable
#   3+  — agent isolated, sudo OK, script returned non-zero. The script's
#         actual exit code is preserved and returned unchanged (so caller
#         can distinguish e.g. 1 = no-keys from 2 = unreadable inside the
#         script's own contract).
#
# stdout: the script's stdout, unmodified.
# stderr: suppressed unless BRIDGE_ISOLATION_HELPERS_DEBUG=1.
#
# Implementation note (#832): does NOT source bridge-lib.sh inside the
# isolated UID's bash invocation. The script must be self-contained.
bridge_isolation_run_as_agent_user_via_bash() {
  local agent="$1"
  local script="$2"
  shift 2 || true

  local os_user=""
  local bash_bin="${BRIDGE_BASH_BIN:-bash}"
  local debug="${BRIDGE_ISOLATION_HELPERS_DEBUG:-0}"
  local rc=0

  [[ -n "$agent" ]] || return 1
  [[ -n "$script" ]] || return 1

  if ! bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    return 1
  fi

  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
  [[ -n "$os_user" ]] || return 1

  if ! command -v sudo >/dev/null 2>&1; then
    return 2
  fi

  if ! sudo -n -u "$os_user" "$bash_bin" -c 'exit 0' 2>/dev/null; then
    return 2
  fi

  if [[ "$debug" == "1" ]]; then
    sudo -n -u "$os_user" "$bash_bin" -c "$script" bridge-isolation "$@"
    rc=$?
  else
    sudo -n -u "$os_user" "$bash_bin" -c "$script" bridge-isolation "$@" 2>/dev/null
    rc=$?
  fi

  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  # Preserve the script's exit code unchanged for caller's distinct mapping.
  # `sudo` itself returns 1 on policy denial — we already filtered that case
  # above via the pre-flight true-probe, so any non-zero here is the script.
  # Force-shift into the 3+ band so callers can disambiguate from rc=1/2.
  if [[ "$rc" -lt 3 ]]; then
    return $((rc + 2))
  fi
  return "$rc"
}
