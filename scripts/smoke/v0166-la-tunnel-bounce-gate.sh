#!/usr/bin/env bash
# scripts/smoke/v0166-la-tunnel-bounce-gate.sh — Lane-A #1733 WARP tunnel-health
# bounce-GATING + soft-refresh (v0.16.6 quiet/seamless mesh).
#
# #1706's tunnel_health adapter bounced the WHOLE WARP tunnel on handshake-idle
# ALONE (age > 120s), even when every peer was UP — severing the very `10.128.x`
# A2A mesh that rides the tunnel (live #1733: a bounce at 275s idle, all peers
# UP). This lane gates the full disconnect/connect bounce (codex design-
# consensus #11698): it fires ONLY on a CORRELATION — stale handshake AND >=N
# consecutive stale ticks AND >=1 FRESH peer suspect/down (read from the prior-
# tick reachability FSM in reconcile.db) AND a soft-refresh (`warp-cli connect`,
# NEVER disconnect) was tried first. All-peers-fresh-up, or unknown/stale peer
# state, HARD-suppresses the bounce with an observable reason.
#
# Asserted (all against an ISOLATED BRIDGE_HOME under a tmpdir — never live
# bridge state; all Python driving is via the *-helper.py file-as-argv sidecar,
# footgun #11: NO heredoc-stdin; the warp-cli is MOCKED via BRIDGE_A2A_WARP_CLI
# and the bounce/soft-refresh hooks are injected spies so NO real WARP host is
# touched; the peer FSM rows are seeded directly into reconcile.db):
#   (a) ALL-UP        — stale handshake + ALL peers FRESH-up -> NO bounce (the
#       #1733 regression guard) + bounce_suppressed_reason=all_peers_fresh_up.
#   (b) LOSS-BOUNCES  — stale + >=1 FRESH peer down + N consecutive stale ticks
#       + soft-refresh-first -> the bounce DOES fire (exactly once, soft first).
#   (c) SINGLE-STALE  — a single stale tick (streak N=1) -> NO bounce.
#   (d) UNKNOWN-STALE — stale + peer state unknown/stale -> NO bounce + reason
#       peer_state_unknown_or_stale.
#   (e) SOFT-FIRST    — the soft-refresh is attempted BEFORE any full bounce.
#   (f) SOFT-NO-DISC  — the default soft-refresh nudges via `warp-cli connect`
#       and NEVER calls `warp-cli disconnect`.
#
# Run green on /opt/homebrew/bin/bash (macOS) and Linux CI bash.

set -euo pipefail

SMOKE_NAME="v0166-la-tunnel-bounce-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/scripts/smoke/${SMOKE_NAME}-helper.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_assert_file_exists "$HELPER" "lane-A helper present"

# Isolated BRIDGE_HOME — the reconcile.db lands under $BRIDGE_STATE_DIR/handoff,
# never the operator's live runtime.
smoke_setup_bridge_home "$SMOKE_NAME"

# --- mock warp-cli: every invocation appends its FIRST argv token to
# WARP_CALL_LOG so the soft-no-disc check can prove the soft-refresh only ever
# `connect`s (never `disconnect`s). `tunnel stats` prints a stale handshake age;
# `connect`/`disconnect` succeed. The bounce/soft-refresh in the gate tests are
# INJECTED spies, so this CLI's connect/disconnect legs are only exercised by
# the soft-no-disc case that runs the REAL default primitive. ---
write_mock_warp_cli() {
  local cli="$SMOKE_TMP_ROOT/warp-cli-mock"
  cat >"$cli" <<'EOF'
#!/usr/bin/env bash
# Mock warp-cli. Logs the first non-flag subcommand to WARP_CALL_LOG. Ignores
# --accept-tos.
args=()
for a in "$@"; do
  [[ "$a" == "--accept-tos" ]] && continue
  args+=("$a")
done
sub="${args[0]:-}"
rest="${args[1]:-}"
if [[ -n "${WARP_CALL_LOG:-}" ]]; then
  printf '%s\n' "$sub" >>"$WARP_CALL_LOG"
fi
case "$sub" in
  status)
    echo "Status update: Connected"
    ;;
  tunnel)
    if [[ "$rest" == "stats" ]]; then
      echo "Tunnel Protocol: MASQUE (HTTPS via UDP)"
      echo "Time since last handshake: ${WARP_HANDSHAKE_AGE:-5106}s"
    fi
    ;;
  connect|disconnect)
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

WARP_CLI="$(write_mock_warp_cli)"
WARP_CALL_LOG="$SMOKE_TMP_ROOT/warp-call.log"
: >"$WARP_CALL_LOG"

# Point the adapter's CLI seam at the mock + expose the call log for every run.
export BRIDGE_A2A_WARP_CLI="$WARP_CLI"
export WARP_CALL_LOG

run_helper() {
  python3 "$HELPER" "$1" "$REPO_ROOT"
}

# --- (a) all-up: stale handshake + every peer FRESH-up -> NO bounce ---
out_all_up="$(run_helper all-up)"
smoke_assert_contains "$out_all_up" "OK all-up" "(a) stale tunnel + all peers FRESH-up -> NO bounce (#1733 regression)"
smoke_assert_contains "$out_all_up" "bounces=0" "(a) an all-up mesh is never bounced on handshake-idle"
smoke_assert_contains "$out_all_up" "all_peers_fresh_up" "(a) suppression carries the observable reason"

# --- (b) loss-bounces: stale + fresh peer down + N consecutive + soft-first ---
out_loss="$(run_helper loss-bounces)"
smoke_assert_contains "$out_loss" "OK loss-bounces" "(b) stale + fresh peer loss + N-streak + soft-first -> bounce fires"
smoke_assert_contains "$out_loss" "bounces=1" "(b) the gated bounce fires exactly once (on the N-th stale tick)"
smoke_assert_contains "$out_loss" "order=['soft', 'bounce']" "(b) soft-refresh ran BEFORE the full bounce"

# --- (c) single-stale: one stale tick (streak below N) -> no bounce ---
out_single="$(run_helper single-stale)"
smoke_assert_contains "$out_single" "OK single-stale" "(c) a single stale tick does NOT bounce"
smoke_assert_contains "$out_single" "bounces=0" "(c) streak 1 < N suppresses the bounce"
smoke_assert_contains "$out_single" "stale_streak_below_threshold" "(c) suppression reason is the streak gate"

# --- (d) unknown-stale: peer state unknown/stale -> no bounce + reason ---
out_unknown="$(run_helper unknown-stale)"
smoke_assert_contains "$out_unknown" "OK unknown-stale" "(d) unknown/stale peer state -> NO bounce"
smoke_assert_contains "$out_unknown" "bounces=0" "(d) unknown is neither all-up nor loss — never a bounce"
smoke_assert_contains "$out_unknown" "peer_state_unknown_or_stale" "(d) suppression carries the unknown reason"

# --- (d2) mixed-loss-stale: a fresh-down peer + a stale/unknown peer -> NO
#     bounce even with the N-streak satisfied (codex P1 #11705 bypass guard) ---
out_mixed="$(run_helper mixed-loss-stale)"
smoke_assert_contains "$out_mixed" "OK mixed-loss-stale" "(d2) fresh-loss + a stale/unknown peer -> NO bounce (incomplete picture suppresses)"
smoke_assert_contains "$out_mixed" "bounces=0" "(d2) a single fresh loss is not proof while another peer's state is unknown"
smoke_assert_contains "$out_mixed" "peer_state_unknown_or_stale" "(d2) suppression carries the unknown reason, not a loss bounce"

# --- (e) soft-first: soft-refresh precedes any full bounce ---
out_soft_first="$(run_helper soft-first)"
smoke_assert_contains "$out_soft_first" "OK soft-first" "(e) soft-refresh is attempted before any full bounce"

# --- (f) soft-no-disc: the soft-refresh never calls warp-cli disconnect ---
out_soft_nd="$(run_helper soft-no-disc)"
smoke_assert_contains "$out_soft_nd" "OK soft-no-disc" "(f) default soft-refresh nudges via connect, never disconnect"

# --- (g) #1732 x #1733 cross-lane: a TRANSIENT peer's loss is NOT bounce-relevant ---
out_tr_only="$(run_helper transient-only)"
smoke_assert_contains "$out_tr_only" "OK transient-only" "(g) transient-only DOWN mesh -> NO bounce (transient peer not bounce-relevant)"
smoke_assert_contains "$out_tr_only" "bounces=0" "(g) a transient peer going down never bounces the WARP tunnel"

out_pu_td="$(run_helper persistent-up-transient-down)"
smoke_assert_contains "$out_pu_td" "OK persistent-up-transient-down" "(h) persistent-UP + transient-DOWN -> NO bounce (the bounce-relevant peer is up)"
smoke_assert_contains "$out_pu_td" "bounces=0" "(h) a transient-down peer alongside a healthy persistent peer never bounces"

out_pd_tu="$(run_helper persistent-down-transient-up)"
smoke_assert_contains "$out_pd_tu" "OK persistent-down-transient-up" "(i) persistent-DOWN + transient-UP -> bounce STILL fires after N-streak (transient must not dilute a real loss)"

smoke_log "ALL CHECKS PASSED ($SMOKE_NAME)"
