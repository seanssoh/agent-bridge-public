#!/usr/bin/env bash
# lib/bridge-resource-guard.sh — Issue #1454-incident (process-explosion fail-safe).
#
# P0a of the 2026-06-03 incident: Agent Bridge had NO resource-threshold
# fail-safe on its transitive process tree. A long-lived runtime accumulated
# thousands of orphaned codex/mcp-server/node/bash processes; memory exhaustion
# made `fork()` itself fail (child-side SIGSEGV pre-exec), and the daemon kept
# dispatching/spawning right up until the machine could no longer create any
# process → forced reboot.
#
# This module is a defense-in-depth pre-flight probe the daemon (and any other
# spawn site) calls BEFORE forking a new disposable child / refresh worker /
# agent. When the host is near a resource ceiling it returns "defer" so the
# caller skips the spawn and warns, instead of pushing the host over fork().
#
# Design contract (mirrors the existing #263 `bridge_check_memory_pressure`):
#   - FAIL OPEN. Any probe glitch (sysctl missing, /proc unreadable, malformed
#     output) returns "healthy/proceed" — a probe error must NEVER block work.
#   - The pressure verdict is a STRICT yes: only when we have positive evidence
#     the host is constrained (memory OR per-uid process count near the cap).
#   - Pure bash + coreutils; no python on the probe path (runs every tick).
#   - Portable: Darwin (sysctl) + Linux (/proc, ulimit). Other → healthy.
#
# Tunables (env):
#   BRIDGE_RESOURCE_GUARD_ENABLED         1 (default) | 0 to disable the guard.
#   BRIDGE_RESOURCE_PROC_PCT_LIMIT        per-uid live process count ceiling as
#                                         a percent of kern.maxprocperuid /
#                                         ulimit -u. Default 70. At/above → defer.
#   BRIDGE_CRON_SWAP_PCT_LIMIT            (reused) Darwin swap-used percent →
#                                         defer. Default 80.
#   BRIDGE_CRON_MIN_AVAIL_MB             (reused) Linux MemAvailable floor (MB) →
#                                         defer below. Default 512.
#
# Returns from bridge_resource_guard_should_defer():
#   0 — DEFER: host is pressured; caller should skip the spawn + warn.
#   1 — PROCEED: host appears healthy (or guard disabled / unknown platform).
# (0=defer is deliberate so callers read `if bridge_resource_guard_should_defer; then skip`.)

# --- per-uid live process count vs the kernel ceiling -------------------------
# Echoes "<count> <max> <pct>" on success, nothing on probe failure (fail open).
bridge_resource_guard_proc_stats() {
  local uid count max kind
  uid="$(id -u 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1

  # Live process count for this uid. `ps -u <uid>` is portable; subtract the
  # header line. (We count processes, not threads — the fork() ceiling is
  # per-process.)
  count="$(ps -u "$uid" -o pid= 2>/dev/null | grep -c . 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || return 1

  kind="$(uname -s 2>/dev/null || true)"
  case "$kind" in
    Darwin)
      max="$(sysctl -n kern.maxprocperuid 2>/dev/null || true)"
      ;;
    Linux)
      # ulimit -u is the per-uid RLIMIT_NPROC soft cap. `unlimited` → no ceiling.
      max="$(ulimit -u 2>/dev/null || true)"
      [[ "$max" == "unlimited" ]] && return 1
      ;;
    *)
      return 1
      ;;
  esac
  [[ "$max" =~ ^[0-9]+$ ]] || return 1
  (( max > 0 )) || return 1

  local pct=$(( count * 100 / max ))
  printf '%s %s %s' "$count" "$max" "$pct"
}

# Returns 0 (defer) when per-uid process count is at/above the percent ceiling.
bridge_resource_guard_proc_pressured() {
  local limit stats pct
  limit="${BRIDGE_RESOURCE_PROC_PCT_LIMIT:-70}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=70
  stats="$(bridge_resource_guard_proc_stats)" || return 1   # probe failed → not pressured
  pct="${stats##* }"
  [[ "$pct" =~ ^[0-9]+$ ]] || return 1
  (( pct >= limit )) && return 0
  return 1
}

# Memory pressure — delegate to the #263 `bridge_check_memory_pressure`
# (lib/bridge-cron.sh), which bridge-lib.sh always sources BEFORE this module.
# We intentionally do NOT inline a duplicate sysctl/awk parser: that re-introduced
# the here-string footgun #11 surface (PR #1479 r1 ratchet) and duplicated the
# single source of truth. If the helper is somehow unavailable (a standalone
# source without bridge-cron.sh), skip the memory check and return not-pressured
# — that is fail-open by design; the per-uid proc-count gate still guards.
bridge_resource_guard_mem_pressured() {
  declare -F bridge_check_memory_pressure >/dev/null 2>&1 || return 1
  # bridge_check_memory_pressure returns 1 when pressured, 0 when healthy.
  bridge_check_memory_pressure && return 1 || return 0
}

# bridge_resource_guard_should_defer [context-label]
#   0 — DEFER (host pressured: memory OR per-uid process count near ceiling)
#   1 — PROCEED (healthy / guard disabled / unknown platform / probe glitch)
# Emits a single human-readable reason on stderr when deferring so callers can
# audit it; the caller owns the audit-log / channel-alert side effect.
bridge_resource_guard_should_defer() {
  local ctx="${1:-dispatch}"
  [[ "${BRIDGE_RESOURCE_GUARD_ENABLED:-1}" == "1" ]] || return 1

  if bridge_resource_guard_mem_pressured; then
    printf 'resource-guard: DEFER %s — memory pressure\n' "$ctx" >&2
    return 0
  fi
  if bridge_resource_guard_proc_pressured; then
    local stats; stats="$(bridge_resource_guard_proc_stats 2>/dev/null || true)"
    printf 'resource-guard: DEFER %s — per-uid process count near ceiling (%s)\n' "$ctx" "${stats:-?}" >&2
    return 0
  fi
  return 1
}

# --- throttle state for the deferral warning ----------------------------------
# A pressured host fans out many spawn attempts per daemon tick across several
# sites. We must NOT emit a warn line (let alone a channel-bound one) per
# attempt — that re-creates the very log/inbox flood this incident is about.
# Throttle to one warn per BRIDGE_RESOURCE_GUARD_WARN_THROTTLE_SECONDS (default
# 300s) across all sites, keyed off a single state file. The audit row is
# always written (forensic trail, file-only, no channel side effect); only the
# operator-visible warn is throttled.
bridge_resource_guard_warn_throttle_path() {
  local dir="${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
  printf '%s/resource-guard.warn.ts' "$dir"
}

# Returns 0 (emit) when the throttle window has elapsed (and records now),
# 1 (suppress) when still within the window. Fails OPEN toward "emit" on any
# state-file glitch — a throttle bookkeeping error must never silence a real
# pressure warning, and an over-emit is harmless relative to under-emit.
bridge_resource_guard_warn_should_emit() {
  local now_ts last_ts window path tmp
  window="${BRIDGE_RESOURCE_GUARD_WARN_THROTTLE_SECONDS:-300}"
  [[ "$window" =~ ^[0-9]+$ ]] || window=300
  now_ts="$(date +%s 2>/dev/null || printf '0')"
  [[ "$now_ts" =~ ^[0-9]+$ ]] || return 0
  path="$(bridge_resource_guard_warn_throttle_path)"
  if [[ -f "$path" ]]; then
    last_ts="$(<"$path")" 2>/dev/null || last_ts=0
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
    (( now_ts - last_ts < window )) && return 1
  fi
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
  tmp="${path}.tmp.$$"
  if printf '%s' "$now_ts" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# bridge_resource_guard_defer_or_proceed <ctx>
#   The single call every daemon spawn site makes. On host pressure it:
#     - writes a `resource_guard_deferred` audit row (file-only, always), and
#     - emits ONE throttled `bridge_warn` line (no channel spam),
#     then returns 0 so the caller skips the spawn and leaves work queued.
#   On a healthy host / disabled guard / unknown platform / probe glitch it
#   returns 1 (PROCEED) — fail OPEN, never wedge the daemon.
# Side effects (audit + warn) are each `|| true`-guarded so a logging error
# cannot leak a non-zero rc back into the daemon poll loop.
bridge_resource_guard_defer_or_proceed() {
  local ctx="${1:-dispatch}"
  bridge_resource_guard_should_defer "$ctx" || return 1

  local stats reason="resource_pressure"
  stats="$(bridge_resource_guard_proc_stats 2>/dev/null || true)"
  if declare -F bridge_audit_log >/dev/null 2>&1; then
    bridge_audit_log daemon resource_guard_deferred daemon \
      --detail context="$ctx" \
      --detail proc_stats="${stats:-unknown}" \
      --detail reason="$reason" >/dev/null 2>&1 || true
  fi
  if bridge_resource_guard_warn_should_emit; then
    if declare -F bridge_warn >/dev/null 2>&1; then
      bridge_warn "resource-guard: deferred spawn (${ctx}) — host near resource ceiling (${stats:-?}); leaving work queued" || true
    fi
  fi
  return 0
}
