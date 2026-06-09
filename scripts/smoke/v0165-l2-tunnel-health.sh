#!/usr/bin/env bash
# scripts/smoke/v0165-l2-tunnel-health.sh — Lane-2 per-transport tunnel_health
# adapter + bounded WARP auto-bounce (#1706, v0.16.5 A2A Rooms zero-touch mesh).
#
# Lane 2 fills the tunnel_health(transport, cfg) adapter SEAM Lane 0 defined.
# It probes ONLY the configured transport's substrate (a WARP install never
# shells `tailscale` and vice-versa) and, on a PROVEN stale WARP MASQUE
# handshake (the live false-`Connected` 3153s failure), AUTO-bounces the tunnel
# via an INJECTABLE module-level hook — BOUNDED by the reconcile.db backoff gate
# Lane 0 already applies (no bounce storm). net-status only reports; the daemon
# bounces (observable-not-operable).
#
# Asserted (all against an ISOLATED BRIDGE_HOME under a tmpdir — never live
# bridge state; all Python driving is via the *-helper.py file-as-argv sidecar,
# footgun #11: NO heredoc-stdin; the warp-cli/tailscale CLIs are MOCKED via the
# BRIDGE_A2A_WARP_CLI / BRIDGE_A2A_TAILSCALE_CLI seams + the injected bounce
# hook so NO real WARP/Tailscale host is touched):
#   (a) HEALTHY — WARP handshake age < threshold -> converged, NO bounce.
#   (b) STALE   — WARP handshake age > threshold -> transport_degraded + error
#       result + the injected bounce hook WAS invoked (exactly once).
#   (c) BOUNDED — repeated stale ticks driven through run_step do NOT bounce on
#       every call: the backoff gate paces the bounce (tick1 bounces, the
#       backed-off tick is SKIPPED, a far-future tick bounces again).
#   (d) ACTIVE-TRANSPORT-ONLY — the tailscale path never invokes the WARP bounce
#       and the warp path never consults the tailscale CLI.
#   (e) PARSE-FAILURE — a warp-cli with no parseable handshake line -> error
#       WITHOUT a bounce (an unknowable age is not a PROVEN stale handshake).
#   (e') NON-ZERO PROBE — a FAILED `warp-cli tunnel stats` (non-zero exit) whose
#       output still carries a stale-looking handshake line is UNKNOWABLE (rc
#       gate, the #1595 lesson): error WITHOUT a bounce.
#   (f) NO-SECRET — the degraded result carries no secret-shaped field.
#
# Run green on /opt/homebrew/bin/bash (macOS) and Linux CI bash.

set -euo pipefail

SMOKE_NAME="v0165-l2-tunnel-health"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/scripts/smoke/${SMOKE_NAME}-helper.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_assert_file_exists "$HELPER" "lane-2 helper present"

# Isolated BRIDGE_HOME — the reconcile.db lands under $BRIDGE_STATE_DIR/handoff,
# never the operator's live runtime.
smoke_setup_bridge_home "$SMOKE_NAME"

# --- mock warp-cli: emits `Time since last handshake: <N>s` driven by
# WARP_HANDSHAKE_AGE. A non-numeric value prints NO age line (the parse-failure
# case). `disconnect`/`connect` are accepted (the real bounce path is the
# INJECTED hook in these tests, never this CLI) and `status` reports Connected
# so a careless probe still sees the false-`Connected` shape. ---
write_mock_warp_cli() {
  local cli="$SMOKE_TMP_ROOT/warp-cli-mock"
  cat >"$cli" <<'EOF'
#!/usr/bin/env bash
# Mock warp-cli driven by WARP_HANDSHAKE_AGE. Ignores --accept-tos.
args=()
for a in "$@"; do
  [[ "$a" == "--accept-tos" ]] && continue
  args+=("$a")
done
sub="${args[0]:-}"
rest="${args[1]:-}"
case "$sub" in
  status)
    # MASQUE false-Connected shape: status keeps saying Connected even stale.
    echo "Status update: Connected"
    echo "Network: healthy"
    ;;
  tunnel)
    if [[ "$rest" == "stats" ]]; then
      echo "Tunnel Protocol: MASQUE (HTTPS via UDP)"
      age="${WARP_HANDSHAKE_AGE:-12}"
      if [[ "$age" =~ ^[0-9]+$ ]]; then
        echo "Time since last handshake: ${age}s"
      else
        # parse-failure mode: no parseable handshake line.
        echo "Time since last handshake: never"
      fi
      echo "Sent: 5.4MB; Received: 6.4MB"
      # WARP_TUNNEL_RC simulates a FAILED `tunnel stats` query that still
      # printed a (stale leftover) handshake line. A non-zero rc must make the
      # age UNKNOWABLE (no bounce), never a proven stale.
      exit "${WARP_TUNNEL_RC:-0}"
    fi
    ;;
  disconnect|connect)
    # The bounce is the INJECTED hook in the smoke; this CLI never actually
    # bounces a real tunnel. Accept the verb so a default-path bounce (not used
    # here) would not error.
    echo "Success"
    ;;
  *)
    echo "mock warp-cli: unknown subcommand ${sub:-<none>}" >&2
    exit 2
    ;;
esac
exit 0
EOF
  chmod 0755 "$cli"
  printf '%s' "$cli"
}

# --- mock tailscale: emits `status --json` driven by TS_MOCK_MODE.
#   up   -> BackendState=Running + Self.Online=true   (healthy)
#   down -> BackendState=Stopped + Self.Online=false  (degraded)
#   boom -> EXIT NON-ZERO (would fail the probe if wrongly invoked by warp)
# Only `status --json` is implemented. ---
write_mock_tailscale_cli() {
  local cli="$SMOKE_TMP_ROOT/tailscale-mock"
  cat >"$cli" <<'EOF'
#!/usr/bin/env bash
mode="${TS_MOCK_MODE:-up}"
if [[ "$mode" == "boom" ]]; then
  echo "tailscale: simulated failure" >&2
  exit 1
fi
sub="${1:-}"
if [[ "$sub" == "status" ]]; then
  case "$mode" in
    up)   echo '{"BackendState":"Running","Self":{"Online":true,"HostName":"node-a","TailscaleIPs":["100.64.0.1"]}}' ;;
    down) echo '{"BackendState":"Stopped","Self":{"Online":false,"HostName":"node-a","TailscaleIPs":["100.64.0.1"]}}' ;;
    *)    echo '{"BackendState":"NoState","Self":{"Online":false}}' ;;
  esac
  exit 0
fi
echo "mock tailscale: unsupported ${sub:-<none>}" >&2
exit 2
EOF
  chmod 0755 "$cli"
  printf '%s' "$cli"
}

WARP_CLI="$(write_mock_warp_cli)"
TS_CLI="$(write_mock_tailscale_cli)"

# Point the adapter's CLI seams at the mocks for every helper run.
export BRIDGE_A2A_WARP_CLI="$WARP_CLI"
export BRIDGE_A2A_TAILSCALE_CLI="$TS_CLI"

run_helper() {
  python3 "$HELPER" "$1" "$REPO_ROOT"
}

# --- (a) healthy: fresh handshake -> converged, no bounce ---
out_healthy="$(run_helper healthy)"
smoke_assert_contains "$out_healthy" "OK healthy" "(a) fresh WARP handshake -> converged, no bounce"
smoke_assert_contains "$out_healthy" "bounces=0" "(a) a fresh tunnel is never bounced"

# --- (b) stale: aged handshake -> degraded + error + bounce invoked ---
out_stale="$(run_helper stale)"
smoke_assert_contains "$out_stale" "OK stale" "(b) stale WARP handshake -> degraded + auto-bounce"
smoke_assert_contains "$out_stale" "bounces=1" "(b) proven-stale handshake invokes the bounce exactly once"

# --- (c) bounded: backoff gate paces the bounce across ticks ---
out_bounded="$(run_helper bounded)"
smoke_assert_contains "$out_bounded" "OK bounded" "(c) repeated stale ticks do NOT bounce on every call"
smoke_assert_contains "$out_bounded" "bounces=2" "(c) bounce paced by backoff (tick1+tick3, tick2 skipped)"

# --- (d) active-transport-only: no cross-shelling ---
out_active="$(run_helper active-only)"
smoke_assert_contains "$out_active" "OK active-only" "(d) tailscale never invokes WARP bounce; warp never consults tailscale"

# --- (e) parse-failure: unknowable age -> error WITHOUT a bounce ---
out_parse="$(run_helper parse-fail)"
smoke_assert_contains "$out_parse" "OK parse-fail" "(e) unparseable handshake -> error, no bounce"
smoke_assert_contains "$out_parse" "bounces=0" "(e) an unknowable age never triggers a bounce"

# --- (e') nonzero-exit stale-looking line: failed probe is unknowable, no bounce ---
out_nz="$(run_helper nonzero-stale)"
smoke_assert_contains "$out_nz" "OK nonzero-stale" "(e') failed probe (non-zero rc) -> error, no bounce"
smoke_assert_contains "$out_nz" "bounces=0" "(e') a non-zero rc + stale-looking line never bounces (rc gate)"

# --- (f) no-secret: the degraded result exposes no secret-shaped field ---
out_secret="$(run_helper no-secret)"
smoke_assert_contains "$out_secret" "OK no-secret" "(f) degraded result carries no secret-shaped field"

smoke_log "ALL CHECKS PASSED ($SMOKE_NAME)"
