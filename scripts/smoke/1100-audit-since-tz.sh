#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1100-audit-since-tz.sh — Issue #1100.
#
# `agb audit list --since <iso8601>` raised a TypeError on
# v0.14.5-beta4 whenever the operator supplied a naive datetime
# (`--since 2026-05-23T12:00`) and the audit records carried a
# timezone offset (the default produced by `now_iso()`):
#
#   TypeError: can't compare offset-naive and offset-aware datetimes
#
# Root cause: `parse_since` returned `datetime.fromisoformat(raw)`
# verbatim; a naive operator input compared against an aware record
# `ts` aborts. Fix: in `parse_since`, if the parsed datetime is naive,
# attach the operator-local tzinfo so the comparison side at
# `record_matches` is always tz-aware.
#
# This smoke pins:
#   T1. A naive `--since` (`2026-05-23T12:00`) against records with TZ
#       offsets exits 0 and returns the expected window.
#   T2. The same query with an explicit offset (`+09:00`) returns the
#       identical set.
#   T3. Sanity-check: a far-future `--since` returns zero records (the
#       filter still applies; the fix didn't accidentally drop the
#       comparison).
#
# Isolation: temp working dir under /tmp; the smoke never reads or
# writes the operator's live audit log.

set -euo pipefail

SMOKE_NAME="1100-audit-since-tz"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_make_temp_root "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AUDIT_HELPER="$REPO_ROOT/bridge-audit.py"
[[ -f "$AUDIT_HELPER" ]] || smoke_fail "missing helper: $AUDIT_HELPER"

AUDIT_LOG="$SMOKE_TMP_ROOT/audit.jsonl"

# Seed two TZ-aware records that bracket the `--since` boundary used in
# the issue reproduction. Both records are at +09:00 (KST) — the format
# `now_iso()` produces on the host where #1100 was filed.
#
# Pre-12:00 record (should be filtered OUT by `--since 2026-05-23T12:00`):
# Post-12:00 record (should be returned):
cat >"$AUDIT_LOG" <<'EOF'
{"ts":"2026-05-23T11:00:00+09:00","actor":"smoke","action":"pre","target":"pre","detail":{},"pid":1,"host":"smoke","prev_hash":"","hash":"pre-hash"}
{"ts":"2026-05-23T12:51:54+09:00","actor":"smoke","action":"post","target":"post","detail":{},"pid":1,"host":"smoke","prev_hash":"pre-hash","hash":"post-hash"}
EOF

# T1 — Naive `--since` (the issue reproduction case). Pre-fix this
# raised TypeError; post-fix it returns the post-12:00 record only.
test_naive_since() {
  local out="" rc=0
  set +e
  out="$(python3 "$AUDIT_HELPER" list --file "$AUDIT_LOG" \
    --since "2026-05-23T12:00" 2>&1)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T1 naive --since exits 0 (pre-fix this raised TypeError, rc=1)"
  case "$out" in
    *"TypeError"*|*"can't compare offset-naive"*)
      smoke_fail "T1 naive --since still surfaces TypeError: $out"
      ;;
  esac
  smoke_assert_contains "$out" "post" \
    "T1 naive --since returns the post-boundary record"
  smoke_assert_not_contains "$out" "pre-hash" \
    "T1 naive --since does NOT return the pre-boundary record"
}

# T2 — Aware `--since` with an explicit offset also exits 0 and
# returns the same post-boundary record. The fix must not regress the
# already-working aware path.
test_aware_since() {
  local out="" rc=0
  set +e
  out="$(python3 "$AUDIT_HELPER" list --file "$AUDIT_LOG" \
    --since "2026-05-23T12:00+09:00" 2>&1)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T2 aware --since exits 0"
  case "$out" in
    *"TypeError"*|*"can't compare offset-naive"*)
      smoke_fail "T2 aware --since unexpectedly raised: $out"
      ;;
  esac
  smoke_assert_contains "$out" "post" \
    "T2 aware --since returns the post-boundary record"
  smoke_assert_not_contains "$out" "pre-hash" \
    "T2 aware --since does NOT return the pre-boundary record"
}

# T2b — The naive and aware queries must return the SAME records when
# the operator's local tz matches the explicit offset on the aware
# query. We force `TZ=Asia/Seoul` so the local-tz attachment in
# `parse_since` lands on +09:00, matching the seeded record offsets
# and the explicit-offset query. This makes the smoke deterministic on
# any host (CI, mac, Linux), not just KST.
test_naive_matches_aware_in_fixed_tz() {
  local naive_out="" aware_out=""
  naive_out="$(TZ=Asia/Seoul python3 "$AUDIT_HELPER" list \
    --file "$AUDIT_LOG" --since "2026-05-23T12:00" --json 2>&1)"
  aware_out="$(TZ=Asia/Seoul python3 "$AUDIT_HELPER" list \
    --file "$AUDIT_LOG" --since "2026-05-23T12:00+09:00" --json 2>&1)"
  smoke_assert_eq "$aware_out" "$naive_out" \
    "T2b naive and aware --since return identical record sets under TZ=Asia/Seoul"
}

# T3 — A far-future `--since` returns zero records. Confirms the
# filter is actually being applied (vs the fix accidentally dropping
# the comparison and returning everything).
test_future_since_returns_empty() {
  local out="" rc=0
  set +e
  out="$(python3 "$AUDIT_HELPER" list --file "$AUDIT_LOG" \
    --since "2099-01-01T00:00" 2>&1)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T3 future --since exits 0"
  smoke_assert_not_contains "$out" "pre-hash" \
    "T3 future --since filters out the pre record"
  smoke_assert_not_contains "$out" "post-hash" \
    "T3 future --since filters out the post record"
}

smoke_run "T1 naive --since does not TypeError"          test_naive_since
smoke_run "T2 aware --since still works"                 test_aware_since
smoke_run "T2b naive and aware match under TZ=Asia/Seoul" test_naive_matches_aware_in_fixed_tz
smoke_run "T3 far-future --since returns empty"          test_future_since_returns_empty

smoke_log "all checks passed"
