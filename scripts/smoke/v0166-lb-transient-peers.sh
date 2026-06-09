#!/usr/bin/env bash
# scripts/smoke/v0166-lb-transient-peers.sh — Lane-B transient-peer resilience
# (#1732, codex design-consensus #11698; v0.16.6 "quiet/seamless mesh").
#
# A2A peers are frequently personal laptops — connect/disconnect is NORMAL, not
# a fault. Today the CLASSIC per-peer outbox treats every peer like a server:
# drops messages after delivery_max_attempts, and fires a high-priority admin
# alarm hourly. Lane B adds an explicit per-peer `class` (persistent | transient,
# default persistent) so a transient peer:
#   - PARKS (never terminally drops) a retryable failure that hits max-attempts,
#     bounded by a per-peer retention TTL → dead(expired-transient-retention);
#   - still dead-letters PERMANENT failures immediately (any class);
#   - suppresses the [A2A] outbox stuck admin alarm;
#   - resumes seamlessly when the peer returns, via the #1707 peer-reachability
#     UP transition waking its parked rows (NO inline deliver).
#
# This smoke pins the CLASSIC OUTBOX behavior (not just the rooms FSM — rooms
# ride the same per-peer outbox, so this covers rooms too). Every case drives
# the REAL production code (cmd_deliver / _schedule_retry / cmd_outbox /
# cmd_a2a_stuck_decide / peer_reachability_step) against an ISOLATED outbox.db /
# reconcile.db / config under a tmp BRIDGE_HOME via the *-helper.py file-as-argv
# sidecar (footgun #11: NO heredoc-stdin). The outbound probe seam is MOCKED so
# the FSM runs with no real network.
#
# Asserted:
#   (a) transient-park        — transient peer + retryable failure past
#                               delivery_max_attempts → PARKED (status='retry',
#                               NOT dead), backoff capped near-future, lease cleared.
#   (b) transient-ttl-expiry  — a parked transient row older than the retention
#                               TTL → dead(expired-transient-retention); GC reclaims.
#   (c) permanent-still-dead  — a PERMANENT failure (missing secret) on a transient
#                               peer → still `dead` immediately, attempt 0 (any class).
#   (d) reconnect-flush       — the #1707 UP transition wakes the transient peer's
#                               parked rows → pending, next_attempt_ts=0, leases
#                               cleared, with NO inline deliver from the reconcile step.
#   (e) alarm-class-aware     — the outbox-stuck alarm filter SUPPRESSES the
#                               transient peer and KEEPS the persistent peer's alarm.
#   (f) default-persistent    — a peer with NO class opted in is byte-identical:
#                               max-attempts → dead(maxattempts).
#
# Run green on /opt/homebrew/bin/bash (macOS) and Linux CI bash.

set -euo pipefail

SMOKE_NAME="v0166-lb-transient-peers"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/scripts/smoke/${SMOKE_NAME}-helper.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_assert_file_exists "$HELPER" "lane-B helper present"

# Isolated BRIDGE_HOME — the outbox.db / reconcile.db / config land under the tmp
# root, never the operator's live runtime.
smoke_setup_bridge_home "$SMOKE_NAME"

CFG_DIR="$SMOKE_TMP_ROOT/lbcfg"
mkdir -p "$CFG_DIR"

# Run one helper subcommand against a FRESH outbox.db + config so each assertion
# is fully isolated (no cross-test row/FSM leakage). $1 = subcommand.
run_helper() {
  local cmd="$1"
  local db="$CFG_DIR/${cmd}-outbox.db"
  local cfg="$CFG_DIR/${cmd}.json"
  rm -f "$db" "$db-wal" "$db-shm" "$cfg"
  python3 "$HELPER" "$cmd" "$REPO_ROOT" "$db" "$cfg"
}

out_park="$(run_helper transient-park)"
smoke_assert_contains "$out_park" "OK transient-park" \
  "(a) transient peer past max-attempts -> PARKED (retry, not dead), capped backoff, lease cleared"

out_ttl="$(run_helper transient-ttl-expiry)"
smoke_assert_contains "$out_ttl" "OK transient-ttl-expiry" \
  "(b) parked transient row past retention TTL -> dead(expired-transient-retention), GC reclaims"

out_perm="$(run_helper permanent-still-dead)"
smoke_assert_contains "$out_perm" "OK permanent-still-dead" \
  "(c) permanent failure on a transient peer -> still dead immediately (any class)"

out_flush="$(run_helper reconnect-flush)"
smoke_assert_contains "$out_flush" "OK reconnect-flush" \
  "(d) #1707 UP transition wakes parked rows -> pending, ts=0, lease cleared, NO inline deliver"

out_alarm="$(run_helper alarm-class-aware)"
smoke_assert_contains "$out_alarm" "OK alarm-class-aware" \
  "(e) outbox-stuck alarm suppressed for transient, unchanged for persistent"

out_def="$(run_helper default-persistent)"
smoke_assert_contains "$out_def" "OK default-persistent" \
  "(f) a peer with NO class opt-in is byte-identical: max-attempts -> dead(maxattempts)"

smoke_log "ALL CHECKS PASSED ($SMOKE_NAME)"
