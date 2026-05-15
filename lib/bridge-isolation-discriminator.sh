#!/usr/bin/env bash
# shellcheck shell=bash
# lib/bridge-isolation-discriminator.sh — platform-aware isolation-v2 gates.
#
# S3 of the v0.14.x stabilization plan. Centralizes the platform-aware
# policy that S2 introduced as ad-hoc `[[ "$(uname)" == "Darwin" ]]`
# checks. Three predicates:
#
#   bridge_isolation_discriminator_auto_resolve  — resolved (cached)
#                                                   "yes" / "no" value
#                                                   for `BRIDGE_ISOLATION_REQUIRED`
#   bridge_isolation_v2_enforce                  — Bucket 2 enforcement
#                                                   gate (return 0 if v2
#                                                   should enforce here)
#   bridge_isolation_v2_require_linux            — Bucket 3 contract gate
#                                                   (die if not Linux)
#
# Policy:
#
#   - `BRIDGE_ISOLATION_REQUIRED=auto` (default, or unset):
#       Linux → yes (v2 enforces)
#       anything else → no (v2 is a silent no-op)
#   - `BRIDGE_ISOLATION_REQUIRED=yes`: explicit operator opt-in (regardless of OS)
#   - `BRIDGE_ISOLATION_REQUIRED=no`: explicit operator opt-out (regardless of OS)
#
# Call sites should use:
#
#   - Bucket 2 (per-action enforcement):
#       bridge_isolation_v2_enforce || return 0
#   - Bucket 3 (contract — operation requires Linux):
#       bridge_isolation_v2_require_linux       # dies if not Linux
#
# instead of hard-coding `uname == Darwin` checks. The discriminator is
# the single SSOT so future platform support (WSL, BSD, etc.) extends
# in one place.
#
# Sourced after `bridge-agents.sh` (provides `bridge_host_platform`)
# and BEFORE `bridge-isolation-v2.sh` so the v2 module's call sites
# can use these predicates.

# Cache the auto-resolve once per shell. The cache key is the resolved
# string ("yes" or "no"). An empty string means "not yet resolved".
_BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED=""

_bridge_isolation_discriminator_platform() {
  # Standalone-safe platform helper. Prefers BRIDGE_HOST_PLATFORM_OVERRIDE
  # (for testability), then bridge_host_platform when available
  # (full bridge-lib flow), then falls back to direct `uname -s`
  # so the discriminator works when only this module is sourced
  # (e.g., tests/isolation-v2-primitives/smoke.sh).
  if [[ -n "${BRIDGE_HOST_PLATFORM_OVERRIDE:-}" ]]; then
    printf '%s' "$BRIDGE_HOST_PLATFORM_OVERRIDE"
    return 0
  fi
  if command -v bridge_host_platform >/dev/null 2>&1; then
    bridge_host_platform 2>/dev/null
    return $?
  fi
  uname -s 2>/dev/null || printf 'unknown'
}

bridge_isolation_discriminator_auto_resolve() {
  # Returns 0 always; prints the resolved value ("yes" or "no") on stdout.
  # Reads $BRIDGE_ISOLATION_REQUIRED and $BRIDGE_HOST_PLATFORM_OVERRIDE
  # from the calling environment. Result cached in
  # $_BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED (parent-shell var).
  if [[ -n "$_BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED" ]]; then
    printf '%s' "$_BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED"
    return 0
  fi
  local req="${BRIDGE_ISOLATION_REQUIRED:-auto}"
  local resolved
  case "$req" in
    yes|no)
      resolved="$req"
      ;;
    auto|"")
      if [[ "$(_bridge_isolation_discriminator_platform)" == "Linux" ]]; then
        resolved="yes"
      else
        resolved="no"
      fi
      ;;
    *)
      if command -v bridge_warn >/dev/null 2>&1; then
        bridge_warn "BRIDGE_ISOLATION_REQUIRED='$req' is invalid (expected yes|no|auto); treating as auto"
      else
        printf '[discriminator] BRIDGE_ISOLATION_REQUIRED=%q invalid; treating as auto\n' "$req" >&2
      fi
      if [[ "$(_bridge_isolation_discriminator_platform)" == "Linux" ]]; then
        resolved="yes"
      else
        resolved="no"
      fi
      ;;
  esac
  _BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED="$resolved"
  printf '%s' "$resolved"
  return 0
}

bridge_isolation_v2_enforce() {
  # Bucket 2 enforcement gate. Returns 0 (enforce v2) when:
  #   - host is Linux and BRIDGE_ISOLATION_REQUIRED is auto/yes, OR
  #   - operator explicitly set BRIDGE_ISOLATION_REQUIRED=yes
  # Returns 1 (skip v2 enforcement, silent no-op) otherwise.
  #
  # Codex r1 catch (PR #908): MUST NOT wrap auto_resolve in `$()` —
  # the subshell would prevent the cache var from persisting to the
  # parent shell, so every call would re-resolve (and re-warn on
  # invalid BRIDGE_ISOLATION_REQUIRED). Call in-place with output
  # redirected, then read the cache var directly.
  #
  # Usage at call site:
  #   bridge_isolation_v2_enforce || return 0
  bridge_isolation_discriminator_auto_resolve >/dev/null
  [[ "$_BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED" == "yes" ]]
}

bridge_isolation_v2_require_linux() {
  # Bucket 3 contract gate. Operations that REQUIRE Linux (setgid
  # groupadd, named-user ACL, sudo-wrapped privilege escalation) must
  # call this at entry to fail loudly on non-Linux hosts instead of
  # silently no-op'ing.
  #
  # Distinction from _enforce: _enforce answers "should we?" (true/false);
  # _require_linux is an assertion that terminates if the host can't
  # satisfy the contract.
  local platform
  platform="$(_bridge_isolation_discriminator_platform)"
  if [[ "$platform" != "Linux" ]]; then
    if command -v bridge_die >/dev/null 2>&1; then
      bridge_die "operation requires Linux (host platform=$platform)"
    else
      printf '[discriminator][error] operation requires Linux (host platform=%s)\n' "$platform" >&2
      exit 1
    fi
  fi
  return 0
}

bridge_isolation_discriminator_clear_cache() {
  # Test/tool hook: invalidate the resolved cache so a follow-up call
  # to `_auto_resolve` re-reads BRIDGE_ISOLATION_REQUIRED. Not used in
  # production code paths; smoke harnesses that mutate the env var
  # mid-run need this.
  _BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED=""
}
