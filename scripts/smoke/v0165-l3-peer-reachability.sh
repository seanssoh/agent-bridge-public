#!/usr/bin/env bash
# scripts/smoke/v0165-l3-peer-reachability.sh — Lane-3 peer-reachability reconcile
# adapter (#1707, v0.16.5 A2A Rooms zero-touch mesh).
#
# Lane 3 fills the `peer_reachability_step(cfg, conn)` adapter SEAM that Lane 0
# defined: the reconcile `peer-reachability` step drives each configured peer
# through a HYSTERETIC UP→SUSPECT→DOWN→(recovery)→UP state machine via a
# lightweight INJECTABLE outbound TCP probe, persists per-peer FSM state in the
# durable reconcile.db, paces a non-UP peer with the per-peer backoff gate
# (cap + exp backoff + jitter — no reconnect storm), and on an IP-drift
# (this node's own LAN listen.address vanished from every local interface) it
# RECORDS the desired LAN→WARP rebind by delegating to stable_local_addr()
# (Lane 1). The ACTUAL rebind still routes through resolve_bind() — this step
# NEVER binds a socket. This smoke pins the adapter contract so a later lane
# cannot silently regress it.
#
# Asserted (all against an ISOLATED reconcile.db + config under a tmp BRIDGE_HOME;
# all Python driving via the *-helper.py file-as-argv sidecar, footgun #11: NO
# heredoc-stdin). The outbound probe seam is MOCKED (reconcile._PEER_REACHABILITY
# _PROBE rebound to a scripted spy) so the REAL FSM code path runs with no real
# network, and BRIDGE_A2A_IFACE_ADDRS mocks the local interface set for IP-drift:
#   (a) all-up        — every peer reachable → step_converged, all rows up
#                       (idempotent on re-run).
#   (b) hysteresis    — a SINGLE failed probe → suspect (NOT down); N consecutive
#                       → down (no single-probe flap).
#   (c) recovery      — a down peer that probes OK → up (failure counter reset).
#   (d) bounded       — repeated DOWN ticks do NOT re-probe every tick (the
#                       per-peer backoff gate paces reconnects).
#   (e) isolation     — peer A DOWN does not mutate peer B's row.
#   (f) ip-drift      — peer unreachable AND local listen.address absent from
#                       interfaces → desired rebind RECORDED (config updated via
#                       stable_local_addr) but NO bind.
#   (f') no-drift     — peer unreachable but listen.address present → NO rebind
#                       recorded (config unchanged; fail-closed).
#   (g) probe-failure — the probe hook RAISES (infra error) → step_error (NOT
#                       changed), fail-closed (UNKNOWABLE; peer NOT up).
#   (g') clean-down    — a CLEAN determinable-down (probe returns False) →
#                       step_changed (NOT error); infra-error vs clean-down
#                       paths are distinguished.
#   (h) no-secret     — no secret-shaped field in any state row or result.
#
# Run green on /opt/homebrew/bin/bash (macOS) and Linux CI bash.

set -euo pipefail

SMOKE_NAME="v0165-l3-peer-reachability"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/scripts/smoke/${SMOKE_NAME}-helper.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_assert_file_exists "$HELPER" "lane-3 helper present"

# Isolated BRIDGE_HOME — the reconcile.db + config land under the tmp root,
# never the operator's live runtime.
smoke_setup_bridge_home "$SMOKE_NAME"

CFG_DIR="$SMOKE_TMP_ROOT/l3cfg"
mkdir -p "$CFG_DIR"

# Run one helper subcommand against a FRESH reconcile.db + config file so each
# assertion is fully isolated (no cross-test FSM/backoff leakage).
# $1 = subcommand.
run_helper() {
  local cmd="$1"
  local db="$CFG_DIR/${cmd}-reconcile.db"
  local cfg="$CFG_DIR/${cmd}.json"
  rm -f "$db" "$db-wal" "$db-shm" "$cfg"
  BRIDGE_A2A_RECONCILE_DB="$db" \
    BRIDGE_A2A_CONFIG="$cfg" \
    python3 "$HELPER" "$cmd" "$REPO_ROOT" "$db" "$cfg"
}

out_all_up="$(run_helper all-up)"
smoke_assert_contains "$out_all_up" "OK all-up" \
  "(a) every peer reachable -> step_converged, all rows up (idempotent)"

out_hyst="$(run_helper hysteresis)"
smoke_assert_contains "$out_hyst" "OK hysteresis" \
  "(b) single miss -> suspect, N consecutive -> down (no single-probe flap)"

out_rec="$(run_helper recovery)"
smoke_assert_contains "$out_rec" "OK recovery" \
  "(c) down peer probes OK -> up (failure counter reset, step_changed)"

out_bnd="$(run_helper bounded)"
smoke_assert_contains "$out_bnd" "OK bounded" \
  "(d) repeated DOWN ticks do NOT re-probe every tick (backoff paces)"

out_iso="$(run_helper isolation)"
smoke_assert_contains "$out_iso" "OK isolation" \
  "(e) peer A DOWN does not mutate peer B's row (per-peer isolation)"

out_drift="$(run_helper ip-drift)"
smoke_assert_contains "$out_drift" "OK ip-drift" \
  "(f) IP-drift -> desired rebind RECORDED via stable_local_addr, NO bind"

out_nodrift="$(run_helper no-drift-rebind)"
smoke_assert_contains "$out_nodrift" "OK no-drift-rebind" \
  "(f') peer down but listen.address present -> NO rebind (config unchanged)"

out_probefail="$(run_helper probe-failure)"
smoke_assert_contains "$out_probefail" "OK probe-failure" \
  "(g) raising probe (infra error) -> step_error, fail-closed (NOT changed; peer NOT up)"

out_cleandown="$(run_helper clean-down)"
smoke_assert_contains "$out_cleandown" "OK clean-down" \
  "(g') clean determinable-down (probe returns False) -> step_changed (NOT error); infra/clean paths distinguished"

out_secret="$(run_helper no-secret)"
smoke_assert_contains "$out_secret" "OK no-secret" \
  "(h) no secret-shaped field in any state row or result"

smoke_log "ALL CHECKS PASSED ($SMOKE_NAME)"
