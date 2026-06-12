#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-reconcile-apply-gated.sh — Issue #1820.
#
# Exercises the GATED wrapper (lib/bridge-layout-v2-reconcile.sh) in APPLY mode
# end-to-end, covering the pieces the dry-run smoke cannot:
#   T1 — apply copies v1-only memory into v2, backs up BOTH sides, and writes
#        the apply marker (state/migration/layout-v2-reconcile/last-apply.json).
#   T2 — the daemon-quiesce fence REFUSES apply when a daemon is "live"
#        (simulated) and not forced, with a structured JSON error (return 3).
#   T3 — `--force-live-daemon` bypasses the fence (deterministic apply path,
#        independent of any real host daemon).
#   T4 — second apply is idempotent (zero new copies).
#
# Uses --force-live-daemon for the apply assertions so the test is deterministic
# regardless of whether a real daemon runs on the CI host. T2 stubs
# bridge_daemon_all_pids to prove the fence fires.

set -uo pipefail
SMOKE_NAME="1820-reconcile-apply-gated"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  [[ -x /opt/homebrew/bin/bash ]] && BRIDGE_BASH=/opt/homebrew/bin/bash
fi

smoke_setup_bridge_home "$SMOKE_NAME"
BH="$BRIDGE_HOME"; DR="$BRIDGE_DATA_ROOT"

# Seed: agent with v1-only MEMORY + a divergent users pair.
mkdir -p "$BH/agents/acme/users/u1" "$DR/agents/acme/home/users/u1"
printf 'v1-fresh\n' >"$BH/agents/acme/MEMORY.md"
printf 'base\nv1div\n' >"$BH/agents/acme/users/u1/MEMORY.md"
printf 'base\nv2div\n' >"$DR/agents/acme/home/users/u1/MEMORY.md"

run_wrapper() {
  # $1 = extra args. Stub line lets T2 inject a fake live daemon.
  local stub="$1"; shift
  "$BRIDGE_BASH" -c "
    cd '$REPO_ROOT'
    source bridge-lib.sh >/dev/null 2>&1
    source lib/bridge-lock.sh >/dev/null 2>&1
    source lib/bridge-layout-v2-reconcile.sh
    $stub
    BRIDGE_AGENT_IDS=(acme)
    BRIDGE_LAYOUT_V2_RECONCILE_QUIESCE_WAIT=1
    bridge_layout_v2_reconcile_run $*
  " 2>&1
}

# T2 — fence refuses when a daemon is "live" and not forced.
OUT="$(run_wrapper 'bridge_daemon_all_pids() { printf "99999\n"; }' --mode apply)"
RC_LINE="$OUT"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "error" in d and "refused" in d["error"], d' \
  || smoke_fail "T2 FAIL: fence did not refuse a live daemon: $OUT"
smoke_log "T2 PASS: daemon-quiesce fence refuses apply against a live daemon"

# T3 — --force-live-daemon bypasses the fence and applies.
OUT="$(run_wrapper 'bridge_daemon_all_pids() { printf "99999\n"; }' --mode apply --force-live-daemon)"
echo "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["mode"]=="apply", d
copied_rels=[c["rel"] for c in d["copied"]]
assert "MEMORY.md" in copied_rels, ("v1-only MEMORY not copied: "+repr(copied_rels))
assert d["counts"]["conflicted"]==1, d["counts"]
assert d["counts"]["backed_up"]>=1, d["counts"]
' || smoke_fail "T3 FAIL: forced apply did not reconcile as expected: $OUT"
smoke_log "T3 PASS: --force-live-daemon applies (copy v1-only + divergent conflict + backups)"

# T1 — v2 got the copy; backups of both sides; apply marker written.
smoke_assert_file_exists "$DR/agents/acme/home/MEMORY.md" "T1 v1-only MEMORY copied into v2"
[[ -n "$(find "$BRIDGE_STATE_DIR/migration/layout-v2-reconcile/backups" -name 'MEMORY.md' 2>/dev/null | head -1)" ]] \
  || smoke_fail "T1 FAIL: no backup written under state/migration/.../backups"
smoke_assert_file_exists "$BRIDGE_STATE_DIR/migration/layout-v2-reconcile/last-apply.json" "T1 apply marker written"
# conflict archived UNDER v2 (verdict)
[[ -n "$(find "$DR/agents/acme/home/.reconcile-conflicts" -name 'MEMORY.md' 2>/dev/null | head -1)" ]] \
  || smoke_fail "T1 FAIL: divergent conflict not archived under v2"
smoke_log "T1 PASS: copy + both-side backups + apply marker + conflict archived under v2"

# T4 — idempotent second apply (zero new copies).
OUT2="$(run_wrapper 'bridge_daemon_all_pids() { printf "99999\n"; }' --mode apply --force-live-daemon)"
echo "$OUT2" | python3 -c 'import json,sys; d=json.load(sys.stdin); n=d["counts"]["copied"]; assert n==0, ("re-apply copied "+str(n)+" (not idempotent)")' \
  || smoke_fail "T4 FAIL: second apply not idempotent: $OUT2"
smoke_log "T4 PASS: second apply idempotent (zero new copies)"

smoke_log "all reconcile apply-gated tests PASS (#1820)"
