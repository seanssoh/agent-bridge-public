#!/usr/bin/env bash
# shellcheck shell=bash
#
# bridge-isolation-runtime.sh — runtime-only escape hatch for v2 isolation.
#
# v0.8.0 hard-cuts the v1 (named-ACL) isolation path: T1 fails fast on
# legacy markers, T2 deletes the v1 helpers, T3 wires the migration. If
# v2 isolation hits an unforeseen issue post-deploy on a specific
# install, operators need a way to keep agents running while debugging
# without resurrecting the deleted v1 code path.
#
# `BRIDGE_DISABLE_ISOLATION=1` is that hatch. It is intentionally narrow:
#   - launch (bridge-run.sh): skip the v2 secret-env exec wrap and the
#     umask 007 wrap; child runs under the controller UID with the
#     default 0077 umask.
#   - start (bridge-start.sh): skip v2 group/sudo prep; SUDO_WRAP stays
#     inactive and no per-agent env file is written.
#   - status (bridge-agent.sh show): surfaces `isolation: disabled-by-env`
#     so operators can see at a glance that the boundary is off.
#
# The hatch DOES NOT:
#   - re-enable v1 ACL helpers (deleted in T2; resurrection is anti-spec)
#   - mutate the layout marker or any agent isolation_mode (so v2
#     resumes the moment the env unset + restart cycle completes)
#   - call `migrate commit` (legacy paths, if any remain, are preserved)
#
# Setting via env (not a flag) is intentional: the operator must
# restart the daemon and any affected agent to take effect, which
# makes the choice loud and reversible.

bridge_isolation_disabled_by_env() {
  # Returns 0 (true) iff BRIDGE_DISABLE_ISOLATION is set to a truthy
  # value. Truthy = 1 / yes / true / on (case-insensitive). Anything
  # else — including unset, empty, "0", "false" — returns 1 (isolation
  # stays enabled). This is intentionally one-way: the operator is
  # choosing to drop a security boundary, so silence-on-typo is safer
  # than silence-on-set.
  case "${BRIDGE_DISABLE_ISOLATION:-}" in
    1|yes|YES|Yes|on|ON|On|true|TRUE|True)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_isolation_runtime_state() {
  # Print the active runtime isolation state for the status surface.
  #   disabled-by-env  — BRIDGE_DISABLE_ISOLATION is set to a truthy value
  #   v2-active        — BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT set
  #   v2-inactive      — v2 helpers loaded but not in effect (e.g.
  #                      pre-migration legacy install, or a fresh-install
  #                      candidate before marker bootstrap).
  # Callers MUST treat the returned value as opaque text — additive
  # values may be introduced without bumping the caller schema.
  if bridge_isolation_disabled_by_env; then
    printf '%s' "disabled-by-env"
    return 0
  fi
  if bridge_isolation_v2_active 2>/dev/null; then
    printf '%s' "v2-active"
    return 0
  fi
  printf '%s' "v2-inactive"
}
