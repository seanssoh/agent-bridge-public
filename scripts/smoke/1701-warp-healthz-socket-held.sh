#!/usr/bin/env bash
# scripts/smoke/1701-warp-healthz-socket-held.sh — a cloudflare-warp-mesh
# receiver whose self-probe can't hairpin its /32 WARP bind must NOT be
# crash-looped as unhealthy (#1701), while a genuinely dead receiver MUST still
# report healthz_timeout, and Tailscale/LAN behavior must be unchanged.
#
# Problem (#1701): cmd_healthz (bridge-handoffd.py) probes serve liveness via
# GET http://<bind>:<port>/healthz. On a cloudflare-warp-mesh install the bind
# is a point-to-point /32 WARP tunnel IP that CANNOT hairpin a TCP connection to
# itself, so the self-probe ALWAYS fails even when the receiver is healthy and
# serving real peers -> the daemon supervisor crash-loops a healthy receiver
# (last_reason=healthz_timeout, restarts 5/5, auto-restart held) and the node's
# A2A/rooms go down. Tailscale/LAN hairpin normally and are unaffected.
#
# Fix (#1701, probe path ONLY): in cmd_healthz's URLError/OSError/ValueError
# (timeout) branch, IF transport.kind == "cloudflare-warp-mesh", fall back to a
# dependency-free socket-held liveness check (_warp_self_probe_socket_held):
# try to bind the same (addr, port) -> EADDRINUSE means the listen socket is
# still held by the running receiver -> healthy; a clean bind means nothing is
# listening -> healthz_timeout. No serve/auth/POST/HMAC surface is touched.
#
# Asserts (the review gate's teeth):
#   (1) FIX — transport.kind=cloudflare-warp-mesh with the listen socket HELD by
#       a receiver that the HTTP self-probe can't reach (non-hairpin symptom):
#       cmd_healthz returns 0 / `healthy` (the socket-held fallback unbricks a
#       healthy WARP receiver instead of crash-looping it). Pre-fix this was
#       exit 3 / healthz_timeout.
#   (2) TEETH — transport.kind=cloudflare-warp-mesh with NOTHING listening on the
#       bind: cmd_healthz returns 3 / `healthz_timeout`. A dead receiver is NOT
#       falsely reported healthy (clean bind => no EADDRINUSE => fallback says
#       not-alive). This is the negative control that proves the fallback has
#       teeth.
#   (3) OFF-WARP unchanged — transport.kind=tailscale with the listen socket HELD
#       the same way: the socket-held fallback is NOT consulted (it is gated on
#       warp-mesh only), so the HTTP-probe verdict governs -> exit 3 /
#       healthz_timeout. A held-but-HTTP-unreachable Tailscale receiver still
#       reports the wedged-serve reason; full wedge-detection is preserved
#       off-WARP.
#   (4) static teeth — the warp-only gate (TRANSPORT_CLOUDFLARE_WARP_MESH) and
#       the socket-held helper exist in cmd_healthz's timeout branch. Reverting
#       the fix removes these and FAILS (4).
#
# Loopback / test-bind harness (BRIDGE_A2A_ALLOW_TEST_BIND=1, free port) mirrors
# 1629-healthz-not-semaphore-gated.sh / a2a-cross-bridge.sh. Footgun #11: all
# Python driving is via the *-helper.py file-as-argv sidecar. Run with
# /opt/homebrew/bin/bash (Bash 5.x) on macOS.

set -euo pipefail

SMOKE_NAME="1701-warp-healthz-socket-held"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/1701-warp-healthz-socket-held-helper.py"
BIND="127.0.0.1"
# A short probe timeout keeps the held-socket "non-hairpin" case fast: the held
# socket accepts then drops, so the HTTP read fails well within this window.
PROBE_TIMEOUT="2"

export BRIDGE_A2A_ALLOW_TEST_BIND=1

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

config_path() { printf '%s/handoff.local.json' "$BRIDGE_HOME"; }

pick_free_port() { python3 "$HELPER" free-port; }

# Write a minimal but valid handoff config for cmd_healthz: a loopback listen
# (resolves under BRIDGE_A2A_ALLOW_TEST_BIND) and the given transport.kind. No
# peers are needed for the read-only liveness probe. Mode 0600 (load_config
# refuses group/world-readable configs).
write_config() {
  local port="$1" kind="$2"
  mkdir -p "$BRIDGE_HOME"
  {
    printf '{\n'
    printf '  "bridge_id": "bridge-warp",\n'
    if [[ "$kind" == "cloudflare-warp-mesh" ]]; then
      printf '  "transport": { "kind": "cloudflare-warp-mesh" },\n'
    else
      printf '  "transport": { "kind": "tailscale" },\n'
    fi
    printf '  "listen": { "address": "%s", "port": %s, "enqueue_path": "/enqueue", "healthz_path": "/healthz" },\n' "$BIND" "$port"
    printf '  "peers": []\n'
    printf '}\n'
  } >"$(config_path)"
  chmod 0600 "$(config_path)"
}

probe() {
  local port="$1" mode="$2"
  python3 "$HELPER" run-healthz "$(config_path)" "$BIND" "$port" "$mode" "$PROBE_TIMEOUT" 2>/dev/null || true
}

# --- Check (1): FIX — warp-mesh + held socket -> healthy --------------------
check_warp_held_is_healthy() {
  local port out
  port="$(pick_free_port)"
  write_config "$port" "cloudflare-warp-mesh"
  out="$(probe "$port" held)"
  smoke_assert_contains "$out" "RC=0" \
    "(1) FIX: warp-mesh receiver with its listen socket HELD (self-probe can't hairpin) reports exit 0"
  smoke_assert_contains "$out" "REASON=healthy" \
    "(1) FIX: warp-mesh held-socket receiver reports 'healthy' (not crash-looped)"
}

# --- Check (2): TEETH — warp-mesh + nothing listening -> healthz_timeout -----
check_warp_dead_is_timeout() {
  local port out
  port="$(pick_free_port)"
  write_config "$port" "cloudflare-warp-mesh"
  out="$(probe "$port" nothing)"
  smoke_assert_contains "$out" "RC=3" \
    "(2) TEETH: warp-mesh with NOTHING listening still reports exit 3 (a dead receiver is not falsely healthy)"
  smoke_assert_contains "$out" "REASON=healthz_timeout" \
    "(2) TEETH: warp-mesh dead receiver reports 'healthz_timeout' (clean bind => no EADDRINUSE => not alive)"
  smoke_assert_not_contains "$out" "REASON=healthy" \
    "(2) TEETH: warp-mesh dead receiver is NOT reported healthy"
}

# --- Check (3): OFF-WARP unchanged — tailscale + held socket -> timeout -------
check_tailscale_held_not_consulted() {
  local port out
  port="$(pick_free_port)"
  write_config "$port" "tailscale"
  out="$(probe "$port" held)"
  smoke_assert_contains "$out" "RC=3" \
    "(3) OFF-WARP: tailscale held-but-HTTP-unreachable receiver still reports exit 3 (fallback not consulted)"
  smoke_assert_contains "$out" "REASON=healthz_timeout" \
    "(3) OFF-WARP: tailscale keeps full wedge-detection (socket-held fallback gated to warp-mesh only)"
  smoke_assert_not_contains "$out" "REASON=healthy" \
    "(3) OFF-WARP: a held-but-unreachable tailscale receiver is NOT reported healthy by the warp fallback"
}

# --- Check (4): static teeth — the warp-only gate + helper exist -------------
check_source_gate_present() {
  local src
  src="$(cat "$SMOKE_REPO_ROOT/bridge-handoffd.py")"
  smoke_assert_contains "$src" "_warp_self_probe_socket_held" \
    "(4) cmd_healthz has the socket-held liveness fallback helper"
  smoke_assert_contains "$src" "TRANSPORT_CLOUDFLARE_WARP_MESH" \
    "(4) the fallback is gated on the cloudflare-warp-mesh transport"
  smoke_assert_contains "$src" "errno.EADDRINUSE" \
    "(4) liveness is inferred from EADDRINUSE (the listen socket is still held)"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "1701-warp-healthz-socket-held"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"

  smoke_run "(1) FIX: warp-mesh held socket reports healthy (not crash-looped)" check_warp_held_is_healthy
  smoke_run "(2) TEETH: warp-mesh dead receiver still reports healthz_timeout" check_warp_dead_is_timeout
  smoke_run "(3) OFF-WARP: tailscale held socket -> fallback NOT consulted" check_tailscale_held_not_consulted
  smoke_run "(4) static: warp-only gate + socket-held helper present" check_source_gate_present

  smoke_log "passed"
}

main "$@"
