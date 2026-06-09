#!/usr/bin/env bash
# scripts/smoke/1728-test-bind-state-path-guard.sh — #1728 (HIGH, data-loss).
#
# The A2A `BRIDGE_A2A_ALLOW_TEST_BIND` flag gates the loopback socket bind for
# test meshes but did NOT gate the STATE PATH. `handoff_dir()` resolves
# `BRIDGE_STATE_DIR` ahead of `BRIDGE_HOME` in bridge_a2a_common.py and
# bridge_rooms_common.py, so a throwaway test mesh that overrides only per-node
# `BRIDGE_HOME` but inherits a live `BRIDGE_STATE_DIR` (normal on a configured
# host) writes rooms.db / reconcile.db / outbox / inbox into the LIVE state
# tree — clobbering real room membership.
#
# The fix adds a `BRIDGE_A2A_ALLOW_TEST_BIND`-gated state-path guard symmetric
# to the existing bind guard: when the (test-only) flag is set AND the resolved
# state dir is NOT under the active `BRIDGE_HOME`, the A2A/rooms write paths
# fail closed with a clear error pointing at the override knobs, instead of
# silently clobbering the live tree. Production (flag unset) is untouched.
#
# This smoke drives the REAL production code (the module guards + the real
# ensure_handoff_dirs / open_rooms write choke points) against ISOLATED tmp
# dirs via the *-helper.py file-as-argv sidecar (footgun #11: NO heredoc-stdin),
# never the operator's live runtime.
#
# Asserted:
#   (a) override-no-optin-prod    — BRIDGE_STATE_DIR override WITHOUT the opt-in
#                                   (the normal production shape) → guard never
#                                   fires; rooms.db is written normally.
#   (b) override-with-optin-deny  — opt-in + BRIDGE_STATE_DIR pointing OUTSIDE
#                                   BRIDGE_HOME (the footgun) → both module
#                                   guards AND the real write paths fail closed
#                                   (code=test_bind_state_outside_home); the
#                                   live tree stays untouched (no clobber).
#   (c) isolated-under-home-allow — opt-in + BRIDGE_STATE_DIR UNDER the test
#                                   home (correctly isolated mesh) → allowed.
#   (d) no-override-default-allow  — opt-in + NO override → default home/state →
#                                   allowed (the opt-in alone never blocks).
#   (e) pre-fix-would-clobber      — control: guard stubbed out → proves the
#                                   PRE-fix code WOULD write rooms.db into the
#                                   live tree (the guard is what prevents it).
#
# Run green on /opt/homebrew/bin/bash (macOS) and Linux CI bash.

set -euo pipefail

SMOKE_NAME="1728-test-bind-state-path-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/scripts/smoke/${SMOKE_NAME}-helper.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_assert_file_exists "$HELPER" "guard helper present"

# Isolated tmp root — the simulated LIVE state dir + the throwaway test home both
# land under the tmp root, never the operator's live runtime. We do NOT call
# smoke_setup_bridge_home here because it pins BRIDGE_STATE_DIR under BRIDGE_HOME
# (which would never trip the guard); the helper sets the exact env per case.
smoke_make_temp_root "$SMOKE_NAME"

# Run one helper subcommand against FRESH live/home dirs so each assertion is
# fully isolated (no cross-case file leakage). $1 = subcommand.
run_helper() {
  local cmd="$1"
  local live="$SMOKE_TMP_ROOT/${cmd}-live"
  local home="$SMOKE_TMP_ROOT/${cmd}-home"
  rm -rf "$live" "$home"
  python3 "$HELPER" "$cmd" "$REPO_ROOT" "$live" "$home"
}

out_a="$(run_helper override-no-optin-prod)"
smoke_assert_contains "$out_a" "OK override-no-optin-prod" \
  "(a) BRIDGE_STATE_DIR override WITHOUT opt-in (prod shape) -> guard never fires, rooms.db written"

out_b="$(run_helper override-with-optin-deny)"
smoke_assert_contains "$out_b" "OK override-with-optin-deny" \
  "(b) opt-in + state dir OUTSIDE home (footgun) -> fail closed, live tree untouched"

out_c="$(run_helper isolated-under-home-allow)"
smoke_assert_contains "$out_c" "OK isolated-under-home-allow" \
  "(c) opt-in + state dir UNDER test home (isolated mesh) -> allowed"

out_d="$(run_helper no-override-default-allow)"
smoke_assert_contains "$out_d" "OK no-override-default-allow" \
  "(d) opt-in + NO override -> default home/state -> allowed"

out_e="$(run_helper pre-fix-would-clobber)"
smoke_assert_contains "$out_e" "OK pre-fix-would-clobber" \
  "(e) control: guard stubbed -> PRE-fix WOULD clobber the live rooms.db"

smoke_log "ALL CHECKS PASSED ($SMOKE_NAME)"
