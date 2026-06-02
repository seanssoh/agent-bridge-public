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

# Memory pressure — reuse the #263 helper if it has been sourced, else inline a
# byte-for-byte equivalent so this module is usable standalone.
bridge_resource_guard_mem_pressured() {
  if declare -F bridge_check_memory_pressure >/dev/null 2>&1; then
    # bridge_check_memory_pressure returns 1 when pressured, 0 when healthy.
    bridge_check_memory_pressure && return 1 || return 0
  fi
  local kind; kind="$(uname -s 2>/dev/null || true)"
  case "$kind" in
    Darwin)
      local usage_line used_raw total_raw used_int total_int pct
      local limit="${BRIDGE_CRON_SWAP_PCT_LIMIT:-80}"
      [[ "$limit" =~ ^[0-9]+$ ]] || limit=80
      usage_line="$(sysctl -n vm.swapusage 2>/dev/null || true)"
      [[ -n "$usage_line" ]] || return 1
      used_raw="$(awk '{ for (i=1;i<=NF;i++) if ($i=="used") print $(i+2) }' <<<"$usage_line")"
      total_raw="$(awk '{ for (i=1;i<=NF;i++) if ($i=="total") print $(i+2) }' <<<"$usage_line")"
      used_int="${used_raw%%.*}"; total_int="${total_raw%%.*}"
      [[ "$used_int" =~ ^[0-9]+$ && "$total_int" =~ ^[0-9]+$ ]] || return 1
      (( total_int > 0 )) || return 1
      pct=$(( used_int * 100 / total_int ))
      (( pct >= limit )) && return 0
      return 1
      ;;
    Linux)
      local avail_kb threshold_mb threshold_kb
      threshold_mb="${BRIDGE_CRON_MIN_AVAIL_MB:-512}"
      [[ "$threshold_mb" =~ ^[0-9]+$ ]] || threshold_mb=512
      threshold_kb=$(( threshold_mb * 1024 ))
      [[ -r /proc/meminfo ]] || return 1
      avail_kb="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
      [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 1
      (( avail_kb < threshold_kb )) && return 0
      return 1
      ;;
    *)
      return 1
      ;;
  esac
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
