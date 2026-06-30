#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/cardintent-ac-render.sh —
# v0.17.0-beta2 (Model B Adaptive Card) — plugins/teams/cardintent.ts is the
# `cardintent` fence parser + quoteResult Adaptive Card (v1.2) renderer that the
# Teams `reply` tool's text-only path calls via the renderOutbound() seam. This
# smoke pins:
#   - the §10 forbidden-cost-key golden (a forbidden key in the rendered card
#     bytes → text-only fallback, never an attached card),
#   - the graceful never-throw fallback (no fence / invalid JSON / schema fail
#     → text-only, fence stripped, the existing reply path UNCHANGED when no
#     fence is present),
#   - that server.ts actually wires renderOutbound() into the text-only reply
#     path (so the renderer cannot be silently orphaned),
# by running the bun unit suite AND a teeth mutation that neuters the §10 guard
# on a COPY (the live source is shared by concurrent CI smokes — never mutated).
#
# Re-exec under bash 4+ for modern array/string features (matches the sibling
# scripts/smoke/1671-teams-eaddrinuse-diagnostic.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:cardintent-ac-render][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Test plan:
#
#   T1 — Static-source: cardintent.ts carries the §10 vendored forbidden-key
#        set (FORBIDDEN_COST_KEYS) hash-pinned to the crm SSOT, the findForbiddenCostKey guard, the
#        renderOutbound seam, and the hash-pin to the crm SSOT (#92 closed:
#        FORBIDDEN_COST_KEYS_GOLDEN_HASH 99f20d8c + the vendored .gen.json). Pins
#        the contract surface so a refactor can't silently drop the guard or
#        un-pin the golden.
#
#   T2 — Static-source: server.ts imports + calls renderOutbound() on the
#        text-only reply path. Asserts the renderer is actually wired in (an
#        orphaned renderer that nothing calls would be a silent no-op).
#
#   T3 — Behavioural: `bun test cardintent.test.ts` passes (fence extraction,
#        validation, valueState mapping, §10 golden, list/detail render shape,
#        graceful fallback). Requires bun; skipped where bun is absent (the
#        static teeth tests still run everywhere).
#
#   T4 (teeth) — copy cardintent.ts, neuter the §10 guard (findForbiddenCostKey
#        always returns null) on the copy, point the test at the copy, and
#        confirm the suite FAILS. Asserts the §10 + fallback assertions are
#        load-bearing (mutation-proof) without mutating the shared live source.
#
#   T5 — ci-select registration: scripts/ci-select-smoke.sh maps
#        plugins/teams/server.ts to this smoke AND lists it in
#        add_all_required_static.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; the bun test runs
# entirely in-process against the pure cardintent.ts module (no Teams traffic,
# no network, no credentials). Footgun #11: every assertion uses printf/grep/$()
# against temp files — no here-strings into bridge functions.

set -uo pipefail

SMOKE_NAME="cardintent-ac-render"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
TEAMS_DIR="$REPO_ROOT/plugins/teams"
CARDINTENT="$TEAMS_DIR/cardintent.ts"
CARDINTENT_TEST="$TEAMS_DIR/cardintent.test.ts"
TEAMS_SERVER="$TEAMS_DIR/server.ts"
CI_SELECT="$REPO_ROOT/scripts/ci-select-smoke.sh"

[[ -f "$CARDINTENT" ]] || smoke_fail "missing $CARDINTENT"
[[ -f "$CARDINTENT_TEST" ]] || smoke_fail "missing $CARDINTENT_TEST"
[[ -f "$TEAMS_SERVER" ]] || smoke_fail "missing $TEAMS_SERVER"
[[ -f "$CI_SELECT" ]] || smoke_fail "missing $CI_SELECT"

HAS_BUN=0
if command -v bun >/dev/null 2>&1; then
  HAS_BUN=1
fi

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# ---------------------------------------------------------------------
# T1: cardintent.ts carries the §10 guard surface + the vendored hash-pin (#92 closed).
# ---------------------------------------------------------------------
test_t1_cardintent_guard_surface() {
  smoke_log "T1: cardintent.ts has the §10 vendored forbidden-key set + hash-pin + guard + renderOutbound seam (#92 closed)"
  grep -q 'FORBIDDEN_COST_KEYS' "$CARDINTENT" \
    || smoke_fail "T1: §10 forbidden-key set FORBIDDEN_COST_KEYS missing"
  grep -q 'export function findForbiddenCostKey' "$CARDINTENT" \
    || smoke_fail "T1: findForbiddenCostKey guard export missing"
  grep -q 'export function renderOutbound' "$CARDINTENT" \
    || smoke_fail "T1: renderOutbound seam export missing"
  # #92 is now VENDORED (was a placeholder + TODO): the golden is hash-pinned to
  # the crm SSOT (PR#840 @ f9f6094) — assert the pin constant + the new hash.
  grep -q 'FORBIDDEN_COST_KEYS_GOLDEN_HASH' "$CARDINTENT" \
    || smoke_fail "T1: §10 hash-pin constant FORBIDDEN_COST_KEYS_GOLDEN_HASH missing"
  grep -q '99f20d8c8efca4521415a030afd954d555edf0b5b201c3d3b5797b44327fcba7' "$CARDINTENT" \
    || smoke_fail "T1: §10 golden is not hash-pinned to the crm SSOT hash 99f20d8c"
  [[ -f "$(dirname "$CARDINTENT")/forbidden_cost_keys.gen.json" ]] \
    || smoke_fail "T1: vendored forbidden_cost_keys.gen.json provenance file missing"
  smoke_log "T1 PASS"
}

# ---------------------------------------------------------------------
# T2: server.ts wires renderOutbound() into the text-only reply path.
# ---------------------------------------------------------------------
test_t2_server_wires_renderoutbound() {
  smoke_log "T2: server.ts imports + calls renderOutbound() (renderer not orphaned)"
  grep -q "from './cardintent.ts'" "$TEAMS_SERVER" \
    || smoke_fail "T2: server.ts does not import from ./cardintent.ts"
  grep -q 'renderOutbound(' "$TEAMS_SERVER" \
    || smoke_fail "T2: server.ts never calls renderOutbound() — the renderer is orphaned"
  smoke_log "T2 PASS"
}

# ---------------------------------------------------------------------
# Helper: ensure plugins/teams/node_modules present for bun test (the test
# itself imports only ./cardintent.ts, but bun resolves bun-types from
# node_modules). Install on demand exactly as the sibling teams smokes do.
# ---------------------------------------------------------------------
ensure_teams_node_modules() {
  if [[ ! -d "$TEAMS_DIR/node_modules" ]]; then
    smoke_log "ensuring plugins/teams/node_modules present"
    if ! ( cd "$TEAMS_DIR" && bun install --no-summary >&2 ); then
      smoke_fail "bun install in plugins/teams failed"
    fi
  fi
}

# ---------------------------------------------------------------------
# T3: the bun unit suite passes.
# ---------------------------------------------------------------------
test_t3_bun_suite_passes() {
  smoke_log "T3: bun test cardintent.test.ts passes"
  ensure_teams_node_modules
  local out_file="$SMOKE_TMP_ROOT/bun-test.out"
  local rc=0
  ( cd "$TEAMS_DIR" && bun test cardintent.test.ts ) >"$out_file" 2>&1 || rc=$?
  if (( rc != 0 )); then
    smoke_fail "T3: bun test failed (rc=$rc):\n$(cat "$out_file")"
  fi
  grep -qE '[1-9][0-9]* pass' "$out_file" \
    || smoke_fail "T3: bun test reported no passing tests:\n$(cat "$out_file")"
  grep -qE '(^| )0 fail' "$out_file" \
    || smoke_fail "T3: bun test reported failures:\n$(cat "$out_file")"
  smoke_log "T3 PASS"
}

# ---------------------------------------------------------------------
# T4 (teeth): neuter the §10 guard on a COPY and confirm the suite FAILS.
# ---------------------------------------------------------------------
test_t4_teeth_mutation_caught() {
  smoke_log "T4 (teeth): neutering the §10 guard on a copy MUST make the bun suite fail"
  ensure_teams_node_modules
  # Work in a copy of the plugin dir so the live cardintent.ts (shared by
  # concurrent CI smokes) is never mutated. node_modules is symlinked in so
  # bun can resolve bun-types without a re-install.
  local mut_dir="$SMOKE_TMP_ROOT/teams-mut"
  mkdir -p "$mut_dir"
  cp "$CARDINTENT" "$mut_dir/cardintent.ts"
  cp "$CARDINTENT_TEST" "$mut_dir/cardintent.test.ts"
  cp "$TEAMS_DIR/package.json" "$mut_dir/package.json" 2>/dev/null || true
  cp "$TEAMS_DIR/tsconfig.json" "$mut_dir/tsconfig.json" 2>/dev/null || true
  if [[ -d "$TEAMS_DIR/node_modules" ]]; then
    ln -s "$TEAMS_DIR/node_modules" "$mut_dir/node_modules"
  fi
  # Neuter findForbiddenCostKey: make it always return null (no forbidden key
  # ever detected). The §10 + fallback assertions in the suite MUST then fail.
  perl -0pi -e 's/  for \(const key of forbidden\) \{\n    if \(cardJson\.includes\(key\)\) return key\n  \}\n  return null/  return null \/\/ TEETH-MUTATION/s' "$mut_dir/cardintent.ts"
  if ! grep -q 'TEETH-MUTATION' "$mut_dir/cardintent.ts"; then
    smoke_fail "T4: teeth mutation did not apply (findForbiddenCostKey body shape changed?) — update the mutation"
  fi
  local out_file="$SMOKE_TMP_ROOT/bun-test-mut.out"
  local rc=0
  ( cd "$mut_dir" && bun test cardintent.test.ts ) >"$out_file" 2>&1 || rc=$?
  if (( rc == 0 )); then
    smoke_fail "T4: bun suite PASSED with the §10 guard neutered — the guard is not load-bearing:\n$(cat "$out_file")"
  fi
  smoke_log "T4 PASS (teeth detector tripped: suite failed with the §10 guard neutered)"
}

# ---------------------------------------------------------------------
# T5: ci-select-smoke.sh registers this smoke under the plugins/teams/server.ts
# arm and in add_all_required_static.
# ---------------------------------------------------------------------
test_t5_ci_select_registration() {
  smoke_log "T5: ci-select-smoke.sh registers '$SMOKE_NAME' under the plugins/teams/server.ts arm + add_all_required_static"
  grep -q "$SMOKE_NAME" "$CI_SELECT" \
    || smoke_fail "T5: ci-select-smoke.sh does not reference '$SMOKE_NAME'"
  local arm_start arm_end
  arm_start="$(grep -nE '^\s*plugins/ms365/server\.ts\|plugins/teams/server\.ts' "$CI_SELECT" \
    | head -n 1 | cut -d: -f1)"
  if [[ -z "$arm_start" ]]; then
    smoke_fail "T5: could not find the plugins/ms365/server.ts|plugins/teams/server.ts case arm in ci-select-smoke.sh"
  fi
  arm_end="$(awk -v start="$arm_start" 'NR>=start && /;;/ {print NR; exit}' "$CI_SELECT")"
  if [[ -z "$arm_end" ]]; then
    smoke_fail "T5: could not delimit the teams/server.ts case arm (no ';;' after line $arm_start)"
  fi
  local arm_block
  arm_block="$(sed -n "${arm_start},${arm_end}p" "$CI_SELECT")"
  # Pure-bash substring test (SIGPIPE-safe under pipefail; not a here-string —
  # the heredoc-ban ratchet flags here-strings). See sibling smoke for rationale.
  if [[ "$arm_block" != *"$SMOKE_NAME"* ]]; then
    smoke_fail "T5: '$SMOKE_NAME' not registered under the teams/server.ts arm at lines $arm_start-$arm_end"
  fi
  local req_static_start req_static_end req_block
  req_static_start="$(grep -nE '^add_all_required_static\(\) \{' "$CI_SELECT" | head -n 1 | cut -d: -f1)"
  if [[ -z "$req_static_start" ]]; then
    smoke_fail "T5: add_all_required_static() function not found"
  fi
  req_static_end="$(awk -v start="$req_static_start" 'NR>=start && /^\}/ {print NR; exit}' "$CI_SELECT")"
  if [[ -z "$req_static_end" ]]; then
    smoke_fail "T5: add_all_required_static() function unterminated"
  fi
  req_block="$(sed -n "${req_static_start},${req_static_end}p" "$CI_SELECT")"
  if [[ "$req_block" != *"$SMOKE_NAME"* ]]; then
    smoke_fail "T5: '$SMOKE_NAME' not in add_all_required_static() list"
  fi
  smoke_log "T5 PASS"
}

# ---------------------------------------------------------------------
# Runner.
# ---------------------------------------------------------------------
smoke_run "T1 cardintent-guard-surface" test_t1_cardintent_guard_surface
smoke_run "T2 server-wires-renderoutbound" test_t2_server_wires_renderoutbound

if (( HAS_BUN )); then
  smoke_run "T3 bun-suite-passes" test_t3_bun_suite_passes
  smoke_run "T4 teeth-mutation-caught" test_t4_teeth_mutation_caught
else
  smoke_skip "T3 bun-suite-passes" "bun not on PATH"
  smoke_skip "T4 teeth-mutation-caught" "bun not on PATH"
fi

smoke_run "T5 ci-select-registration" test_t5_ci_select_registration

smoke_log "cardintent-ac-render: ALL TESTS PASS"
exit 0
