#!/usr/bin/env bash
# scripts/smoke/v0165-l0-reconcile-skeleton.sh — Lane-0 reconcile control-loop
# framework: durable backoff store + ordered idempotent reconcile sequence +
# adapter-stub fail-safe + status-snapshot shape (#1716, v0.16.5 A2A Rooms mesh).
#
# Lane 0 is the FOUNDATION for the zero-touch mesh: it ships the control-loop
# SKELETON + the durable backoff state (state/handoff/reconcile.db) + the four
# adapter SEAMS the staged recovery lanes (#1705/#1706/#1707) and the roster
# anti-entropy (#1695-P2) fill WITHOUT re-touching reconcile_once. This smoke
# pins the framework contract so a later lane cannot silently regress it.
#
# Asserted (all against an ISOLATED BRIDGE_HOME under a tmpdir — never live
# bridge state; all Python driving is via the *-helper.py file-as-argv sidecar,
# footgun #11: NO heredoc-stdin):
#   (a) IDEMPOTENT — running the daemon-side reconcile step sequence
#       (bridge-handoffd.py:_run_reconcile_steps) twice on a fixture cfg is a
#       no-op the second time: identical per-step outcomes, attempt_count stays
#       0 for every step (no state churn beyond the refreshed timestamps).
#   (b) BOUNDED BACKOFF — a non-converged (error) result writes a
#       next_eligible_ts in the FUTURE, a second error grows it exponentially,
#       the delay is CAPPED, and a converged result RESETS attempt_count -> 0
#       and next_eligible_ts -> now.
#   (c) STATUS SNAPSHOT — reconcile_status_snapshot returns the STABLE shape
#       (last_tick_ts / interval / steps) with ALL 5 canonical steps and NO
#       secret-shaped fields (the surface net-status v2 / #1708 consumes).
#   (d) FAIL-SAFE — an adapter that RAISES is caught, recorded as `error`, and
#       the tick STILL completes every later step (a raising step never crashes
#       the daemon tick); AND a store-WRITE failure mid-sequence (corrupt/locked
#       reconcile.db) is contained — no exception escapes _run_reconcile_steps.
#
# Run green on /opt/homebrew/bin/bash (macOS) and Linux CI bash.

set -euo pipefail

SMOKE_NAME="v0165-l0-reconcile-skeleton"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/scripts/smoke/${SMOKE_NAME}-helper.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_assert_file_exists "$HELPER" "lane-0 helper present"

# Isolated BRIDGE_HOME — the reconcile.db lands under $BRIDGE_STATE_DIR/handoff,
# never the operator's live runtime.
smoke_setup_bridge_home "$SMOKE_NAME"

RECONCILE_DB="$BRIDGE_STATE_DIR/handoff/reconcile.db"

pass=0
check() {
  local desc="$1"; shift
  if "$@"; then
    smoke_log "PASS: $desc"
    pass=$((pass + 1))
  else
    smoke_fail "FAIL: $desc"
  fi
}

run_helper() {
  python3 "$HELPER" "$1" "$REPO_ROOT"
}

# --- (a) idempotent ---
out_idem="$(run_helper idempotent)"
smoke_assert_contains "$out_idem" "OK idempotent" "(a) sequence idempotent"
smoke_assert_file_exists "$RECONCILE_DB" "reconcile.db created under isolated state dir"

# --- (b) bounded backoff (exp + cap + converged-reset) ---
out_backoff="$(run_helper backoff)"
smoke_assert_contains "$out_backoff" "OK backoff" "(b) bounded backoff"

# --- (c) status snapshot stable shape + no secrets ---
out_snap="$(run_helper snapshot)"
smoke_assert_contains "$out_snap" "OK snapshot" "(c) status snapshot shape"
# Every canonical step id must appear in the snapshot key list the helper prints.
for step in stable-addr bind-reprove tunnel-health peer-reachability roster-epoch; do
  smoke_assert_contains "$out_snap" "$step" "(c) snapshot enumerates $step"
done

# --- (d) fail-safe: raising adapter caught, tick completes ---
out_raises="$(run_helper raises)"
smoke_assert_contains "$out_raises" "OK raises" "(d) raising adapter fail-safe"
smoke_assert_contains "$out_raises" "tick-completed" "(d) tick completed after raise"

# --- (d') fail-safe: a store-WRITE failure mid-sequence does not escape ---
out_escape="$(run_helper escape)"
smoke_assert_contains "$out_escape" "OK escape" "(d') store-write failure contained"

# --- static teeth: the reconcile.db perms are 0600 (no secrets, but durable
# state stays owner-only, mirroring outbox/inbox) ---
stat_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo '?'
}
mode="$(stat_mode "$RECONCILE_DB")"
smoke_assert_eq "600" "$mode" "reconcile.db is 0600"

smoke_log "ALL CHECKS PASSED ($SMOKE_NAME)"
