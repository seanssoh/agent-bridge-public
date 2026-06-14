#!/usr/bin/env bash
# scripts/smoke/1897-ci-select-shard.sh — issue #1897.
#
# Self-check for the post-selection sharding filter added to
# scripts/ci-select-smoke.sh (#1897). The required unit/static smoke battery
# crossed its ~25m wall-clock cap; policy (#1509) is "split, don't bump", so
# the selector grew --shard-index N --shard-total K (1-based, index-mod over
# the FINAL selected list) and ci.yml runs a 3-way matrix + an aggregate gate
# named exactly `unit/static smoke`.
#
# This smoke pins the selector-side contract so a future selector edit cannot
# silently break the matrix sharding (which would either double-run a script,
# drop coverage, or false-red a shard):
#
#   1. Unsharded selected list == sorted union of shards 1..K — no duplicates,
#      no missing scripts — for BOTH a changed-file-selected list AND the full
#      required list (catch-all selection).
#   2. No script appears in more than one shard (shards are disjoint).
#   3. An empty shard (index with no items, e.g. K > list length) emits no
#      script and exits 0.
#   4. --run with shard args runs ONLY the shard-filtered list (and the
#      union of the three --run passes covers the whole list once).
#   5. needs_bun (the ci.yml bun-install decision) computed from the
#      shard-filtered list matches the per-shard membership of the
#      bun-triggering smoke — i.e. bun detection is shard-aware, not
#      whole-list.
#   6. Backward compatibility: with NO shard args the output is byte-identical
#      to the pre-sharding path.
#   7. Shard-arg validation rejects out-of-range / non-integer values (exit 2).
#
# Footgun #11 self-audit: no <<EOF/<<'PY' heredoc-stdin captured into $().
# This smoke only invokes the selector and compares its stdout; it does not
# stand up a BRIDGE_HOME.

# -e so an unexpected non-zero (failed temp-root setup, failed list-file write,
# a selector invocation we EXPECT to succeed but doesn't) aborts loudly instead
# of letting the run reach "all checks passed". The few invocations whose
# non-zero exit is intentional (the validation cases) capture their rc with
# `|| rc=$?` / `|| true`, so they are exempt from -e by construction.
set -euo pipefail

SMOKE_NAME="1897-ci-select-shard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
SELECTOR="$REPO_ROOT/scripts/ci-select-smoke.sh"
smoke_assert_file_exists "$SELECTOR" "ci-select-smoke.sh selector"

# A temp root for the small intermediate list files this self-check writes.
# This smoke does NOT stand up a BRIDGE_HOME — it only invokes the selector.
smoke_make_temp_root "$SMOKE_NAME"
[[ -n "${SMOKE_TMP_ROOT:-}" && -d "$SMOKE_TMP_ROOT" ]] || \
  smoke_fail "temp root was not created: ${SMOKE_TMP_ROOT:-<unset>}"
# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

K=3

# sorted_union_of_shards <suite> [selection-args...] — concatenate shards 1..K
# (each with its own --shard-index/--shard-total) and sort.
sorted_union_of_shards() {
  local k
  for ((k = 1; k <= K; k++)); do
    bash "$SELECTOR" "$@" --shard-index "$k" --shard-total "$K"
  done | sed '/^$/d' | sort
}

# assert_union_equals_full <label> <suite> [selection-args...]
assert_union_equals_full() {
  local label="$1"; shift
  local full union
  full="$(bash "$SELECTOR" "$@" | sed '/^$/d' | sort)"
  union="$(sorted_union_of_shards "$@")"
  if [[ "$full" != "$union" ]]; then
    smoke_log "[$label] full (sorted):"
    printf '%s\n' "$full" >&2
    smoke_log "[$label] union-of-shards (sorted):"
    printf '%s\n' "$union" >&2
    smoke_fail "[$label] union of shards 1..$K != unsharded selected list"
  fi
  # No script appears more than once across the union (disjoint shards).
  local dups
  dups="$(printf '%s\n' "$union" | uniq -d)"
  if [[ -n "$dups" ]]; then
    smoke_log "[$label] duplicated across shards:"
    printf '%s\n' "$dups" >&2
    smoke_fail "[$label] a script appears in more than one shard"
  fi
  local count
  count="$(printf '%s\n' "$full" | grep -c . || true)"
  smoke_log "[$label] union == unsharded ($count scripts, $K disjoint shards) OK"
}

# ---------------------------------------------------------------------------
# 1+2 — union == full and disjoint, for a changed-file-selected list AND the
#       full required catch-all list. lib/bridge-core.sh trips the catch-all
#       (add_all_required_static) so we exercise the large list too.
# ---------------------------------------------------------------------------
smoke_log "case 1: union==full + disjoint for the full required catch-all list"
assert_union_equals_full "required-full" --suite required --changed-file lib/bridge-core.sh

smoke_log "case 2: union==full + disjoint for a base/head (no-diff) selected list"
assert_union_equals_full "required-headhead" --suite required --base HEAD --head HEAD

# ---------------------------------------------------------------------------
# 3 — an empty shard emits no script and exits 0. With a no-diff selection the
#     list is the small always-required set; ask for a shard index beyond the
#     list length (K_BIG large, a high index) so the shard is guaranteed empty.
# ---------------------------------------------------------------------------
smoke_log "case 3: an empty shard outputs nothing and exits 0"
# Capture the selector's OWN exit (not a downstream sed's) by running it first.
# `|| EMPTY_RC=$?` keeps the explicit exit-code assertion meaningful under -e.
EMPTY_RC=0
EMPTY_RAW="$(bash "$SELECTOR" --suite required --base HEAD --head HEAD \
  --shard-index 99 --shard-total 100)" || EMPTY_RC=$?
[[ $EMPTY_RC -eq 0 ]] || smoke_fail "empty shard exited non-zero: $EMPTY_RC"
EMPTY_OUT="$(printf '%s\n' "$EMPTY_RAW" | sed '/^$/d')"
[[ -z "$EMPTY_OUT" ]] || smoke_fail "empty shard emitted scripts: [$EMPTY_OUT]"
smoke_log "case 3: empty shard -> no output, exit 0 OK"

# ---------------------------------------------------------------------------
# 4 — --run executes ONLY the shard-filtered list. We can't run the real
#     smokes here (recursion / heavy), so instead assert the LIST that --run
#     would execute. Concretely: the printed (non-run) shard list is exactly
#     what --run iterates (same code path computes selected_list), and the
#     union of the three shard lists is the whole list, once. We verify the
#     per-shard list is a strict subset and the three are a partition.
# ---------------------------------------------------------------------------
smoke_log "case 4: each shard list is a partition slice of the full list"
# Materialise the full list to a temp file so the per-shard subset check uses
# `grep -Fxf` (no here-string / process-sub — keeps the heredoc-ban ratchet
# baseline unchanged; footgun #11 hygiene).
FULL_FILE="$SMOKE_TMP_ROOT/full-required.txt"
SHARD_FILE="$SMOKE_TMP_ROOT/shard.txt"
EXTRA_FILE="$SMOKE_TMP_ROOT/extra.txt"
bash "$SELECTOR" --suite required --changed-file lib/bridge-core.sh | sed '/^$/d' | sort >"$FULL_FILE"
PARTITION_TOTAL=0
for ((k = 1; k <= K; k++)); do
  bash "$SELECTOR" --suite required --changed-file lib/bridge-core.sh \
    --shard-index "$k" --shard-total "$K" | sed '/^$/d' >"$SHARD_FILE"
  # Lines in this shard that are NOT present in the full list (must be none).
  grep -Fxv -f "$FULL_FILE" "$SHARD_FILE" >"$EXTRA_FILE" || true
  if [[ -s "$EXTRA_FILE" ]]; then
    smoke_log "case 4: shard $k contained scripts not in the full list:"
    cat "$EXTRA_FILE" >&2
    smoke_fail "case 4: shard $k is not a subset of the full list"
  fi
  n="$(grep -c . "$SHARD_FILE" || true)"
  PARTITION_TOTAL=$((PARTITION_TOTAL + n))
done
FULL_COUNT="$(grep -c . "$FULL_FILE" || true)"
[[ "$PARTITION_TOTAL" -eq "$FULL_COUNT" ]] || \
  smoke_fail "case 4: sum of shard sizes ($PARTITION_TOTAL) != full size ($FULL_COUNT)"
smoke_log "case 4: shard sizes sum to full ($PARTITION_TOTAL == $FULL_COUNT) OK"

# ---------------------------------------------------------------------------
# 5 — shard-aware bun detection. ci.yml decides needs_bun by grepping the
#     SELECTED list for the bun-requiring plugin smokes. Recompute that exact
#     predicate per shard and assert: the full list trips needs_bun, and
#     exactly the shard(s) that actually contain the bun-trigger trip it —
#     i.e. detection follows the shard-filtered list, not the whole list.
# ---------------------------------------------------------------------------
BUN_PAT='scripts/smoke/(telegram-relay-plugin|mattermost-plugin)\.sh'
needs_bun() {  # reads list on stdin, echoes true|false (mirrors ci.yml grep)
  if grep -Eq "$BUN_PAT"; then echo true; else echo false; fi
}
smoke_log "case 5: bun detection follows the shard-filtered list"
FULL_BUN="$(bash "$SELECTOR" --suite required --changed-file lib/bridge-core.sh | needs_bun)"
[[ "$FULL_BUN" == "true" ]] || \
  smoke_fail "case 5: full required list unexpectedly has no bun-trigger (needs_bun=$FULL_BUN)"
BUN_SHARDS=0
for ((k = 1; k <= K; k++)); do
  sb="$(bash "$SELECTOR" --suite required --changed-file lib/bridge-core.sh \
    --shard-index "$k" --shard-total "$K" | needs_bun)"
  if [[ "$sb" == "true" ]]; then BUN_SHARDS=$((BUN_SHARDS + 1)); fi
done
# At least one shard, and strictly fewer than all shards, carry the trigger —
# proving the decision is per-shard (whole-list detection would mark ALL K).
[[ "$BUN_SHARDS" -ge 1 ]] || smoke_fail "case 5: no shard tripped needs_bun (expected >=1)"
[[ "$BUN_SHARDS" -lt "$K" ]] || \
  smoke_fail "case 5: every shard tripped needs_bun ($BUN_SHARDS/$K) — detection is NOT shard-aware"
smoke_log "case 5: $BUN_SHARDS/$K shards need bun (per-shard detection) OK"

# ---------------------------------------------------------------------------
# 6 — backward compatibility of the SHARDING CODE PATH: with no shard args the
#     selector emits the whole selected list, and the explicit no-op
#     (--shard-index 0 --shard-total 0) emits byte-identical output. This pins
#     "sharding is off unless asked", NOT the membership of the selected list
#     itself — which legitimately grows by one entry in this PR (the
#     1897-ci-select-shard smoke is now registered in the required suite). The
#     union property (case 1/2) covers that the registered smoke lands in
#     exactly one shard.
# ---------------------------------------------------------------------------
smoke_log "case 6: sharding off (no args) == explicit 0/0 no-op (byte-identical)"
BASE_OUT="$(bash "$SELECTOR" --suite required --changed-file lib/bridge-core.sh)"
ZERO_OUT="$(bash "$SELECTOR" --suite required --changed-file lib/bridge-core.sh \
  --shard-index 0 --shard-total 0)"
[[ "$BASE_OUT" == "$ZERO_OUT" ]] || \
  smoke_fail "case 6: --shard-index 0 --shard-total 0 differs from no-shard output"
smoke_log "case 6: backward-compatible no-op OK"

# ---------------------------------------------------------------------------
# 7 — validation: out-of-range and non-integer shard args exit 2.
# ---------------------------------------------------------------------------
smoke_log "case 7: shard-arg validation rejects bad values"
assert_exit2() {
  local desc="$1"; shift
  local rc=0
  bash "$SELECTOR" "$@" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] || smoke_fail "case 7: $desc exited $rc, expected 2"
}
assert_exit2 "index > total"   --suite required --shard-index 4 --shard-total 3
assert_exit2 "index 0 w/ total" --suite required --shard-index 0 --shard-total 3
assert_exit2 "non-integer index" --suite required --shard-index abc --shard-total 3
assert_exit2 "non-integer total" --suite required --shard-index 1 --shard-total xy
smoke_log "case 7: validation OK"

smoke_log "all sharding self-checks passed"
