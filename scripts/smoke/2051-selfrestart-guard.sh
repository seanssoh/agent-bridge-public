#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2051-selfrestart-guard.sh — Issue #2051.
#
# Admin self-restart is a split-brain foot-gun. "Restart" = kill old + launch
# new; when the agent ISSUING the restart IS the target (BRIDGE_AGENT_ID ==
# <agent>), the command that performs the kill/launch runs INSIDE the process
# being killed, so the kill→relaunch handoff has no surviving supervisor and can
# leave two live instances of one identity (double-claimed tasks, conflicting
# memory/state writes, duplicate operator sends). The fix REFUSES a caller-
# identity self-restart before any kill/launch and redirects to the restart-peer
# (or "restart manually" when unset). Restarting a DIFFERENT agent is unchanged.
#
# The fix:
#   1. bridge-agent.sh::run_restart — an early guard (right after
#      bridge_require_agent, ahead of dry-run / preflight / the #1853 detached-
#      relaunch path) that, when BRIDGE_AGENT_ID == <agent> and we are not the
#      detached survivor, calls bridge_die with the refuse guidance — so the
#      kill/launch never runs.
#   2. lib/bridge-agents.sh::bridge_agent_restart_peer — reads the
#      BRIDGE_AGENT_RESTART_PEER roster map (declare -Ag, #2020-safe) and
#      returns the configured supervisor (empty when unset).
#   3. lib/bridge-agents.sh::bridge_agent_restart_self_refused_guidance — the
#      actionable message: names the peer when set, else the manual fallback +
#      how to set BRIDGE_AGENT_RESTART_PEER.
#
# Test plan (mutation-proven — drives the REAL run_restart with stubbed side
# effects; the kill is a sentinel so we can assert it never fired):
#   T1. refuse-self, peer SET   — BRIDGE_AGENT_ID == agent, peer configured:
#       run_restart exits non-zero, message names the peer, the kill sentinel
#       did NOT fire (no restart side-effect).
#   T2. refuse-self, peer UNSET — BRIDGE_AGENT_ID == agent, no peer:
#       run_restart exits non-zero, message says "manually", kill never fired.
#   T3. allow-other             — BRIDGE_AGENT_ID != agent: the guard is NOT
#       taken; run_restart proceeds past it and REACHES the kill (sentinel
#       fires) — the non-self path is unchanged.
#   T4. mutation                — with the guard reverted (caller-identity check
#       removed), a self-restart (BRIDGE_AGENT_ID == agent) PROCEEDS to the kill
#       (the split-brain path) instead of refusing — proving T1/T2 are non-
#       vacuous and the guard is load-bearing.
#   T5. roster-assoc            — BRIDGE_AGENT_RESTART_PEER is associative after
#       sourcing the roster, survives multi-agent population with no index-0
#       collapse (the #2020 regression shape), and the accessor reads back the
#       configured peer / empty when unset.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; never touches the
# operator's live runtime.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses no command
# substitution feeding a heredoc-stdin and no `<<<` here-strings into bridge
# functions.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (macOS ships /bin/bash 3.2).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:2051-selfrestart-guard] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="2051-selfrestart-guard"
SCRIPT_DIR_SMOKE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR_SMOKE/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "2051-selfrestart-guard"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

for fn in \
  bridge_agent_restart_peer \
  bridge_agent_restart_self_refused_guidance \
  bridge_var_is_assoc \
  bridge_reset_roster_maps; do
  if ! declare -F "$fn" >/dev/null; then
    smoke_fail "$fn not defined after sourcing bridge-lib.sh"
  fi
done

# --------------------------------------------------------------------------
# Extract run_restart() from bridge-agent.sh into a sourceable shim so we can
# drive the REAL guard logic with the destructive side effects stubbed. The
# function body is copied verbatim (the guard under test is unmodified); only
# the helper functions it calls are replaced with sentinels below.
# --------------------------------------------------------------------------
RUN_RESTART_SHIM="$SMOKE_TMP_ROOT/run_restart.shim.sh"
awk '
  /^run_restart\(\) \{/ { capture=1 }
  capture { print }
  capture && /^\}$/ { exit }
' "$REPO_ROOT/bridge-agent.sh" > "$RUN_RESTART_SHIM"
[[ -s "$RUN_RESTART_SHIM" ]] || smoke_fail "could not extract run_restart() from bridge-agent.sh"
grep -q '^}$' "$RUN_RESTART_SHIM" || smoke_fail "extracted run_restart() shim is not closed"

# Sentinel file: any stubbed kill/launch appends here. T1/T2 assert it stays
# empty (refuse fired first); T3 asserts it is written (non-self reaches kill).
SIDE_EFFECT_LOG="$SMOKE_TMP_ROOT/restart-side-effect.log"

# Stub the destructive + heavy dependency surface reached at/after the guard so
# the shim runs hermetically. bridge_kill_agent_session is the sentinel: it
# records the kill and then exits 0 (we never want the real bridge-start.sh
# launch in a smoke). bridge_die is the real one from bridge-core.sh (exit 1).
# The stubs below are invoked INDIRECTLY — the sourced run_restart shim calls
# them — so shellcheck cannot see the call sites.
# shellcheck disable=SC2329  # stubs invoked indirectly by the sourced run_restart shim
install_run_restart_stubs() {
  bridge_require_agent() { :; }
  bridge_agent_linux_user_isolation_effective() { return 1; }   # shared mode
  bridge_agent_os_user() { printf ''; }
  bridge_agent_session() { printf '%s' "${1:-}"; }
  bridge_agent_engine() { printf 'claude'; }
  bridge_agent_source() { printf 'static'; }                    # skip dynamic leg
  bridge_agent_restart_is_self() { return 1; }                  # not the #1853 tmux-only self
  bridge_agent_restart_preflight_reason() { printf ''; }
  bridge_agent_restart_preflight_full_reason() { printf ''; }
  bridge_agent_clear_broken_launch() { :; }
  bridge_agent_session_id() { printf ''; }
  bridge_agent_resume_trusted_marker_write_if_live() { :; }
  bridge_agent_restart_find_pre_update_snapshot() { printf ''; }
  bridge_agent_restart_snapshot_managed_block() { printf ''; }
  bridge_agent_restart_marker_write() { :; }
  bridge_tmux_session_exists() { return 0; }                    # enter the kill block
  bridge_kill_agent_session() {
    printf 'KILL %s\n' "${1:-}" >> "$SIDE_EFFECT_LOG"
    exit 0
  }
  # Defensive: anything past the kill must never run in a smoke.
  bridge_refresh_runtime_state() { :; }
}

# Source the shim once so run_restart is defined; stubs are installed per-test
# (they must be in scope when run_restart is invoked).
# shellcheck source=/dev/null
source "$RUN_RESTART_SHIM"
declare -F run_restart >/dev/null || smoke_fail "run_restart not defined after sourcing the shim"

# run_restart is invoked inside a subshell per test so its `exit` (bridge_die /
# kill sentinel) does not terminate the smoke; stdout+stderr are captured and
# the exit code read via `|| rc=$?`. SCRIPT_DIR / BRIDGE_BASH_BIN are set so any
# unstubbed exec path is well-formed (the kill sentinel exits before launch).

# T1 — refuse self-restart, peer SET (via the real roster accessor). Non-zero
# exit, the configured peer is named, and the kill sentinel never fired.
test_refuse_self_peer_named() {
  : > "$SIDE_EFFECT_LOG"
  local agent="patch"
  local out="" rc=0
  out="$(
    declare -A BRIDGE_AGENT_RESTART_PEER=()
    BRIDGE_AGENT_RESTART_PEER["$agent"]="patch-dev"
    install_run_restart_stubs
    SCRIPT_DIR="$REPO_ROOT" BRIDGE_BASH_BIN="$(command -v bash)" \
      BRIDGE_AGENT_ID="$agent" BRIDGE_RESTART_DETACHED="" TMUX="" \
      run_restart "$agent" 2>&1
  )" || rc=$?
  smoke_assert_eq "$rc" "1" "T1 refused self-restart exits non-zero"
  smoke_assert_contains "$out" "cannot restart its own session" "T1 refuse message states the split-brain reason"
  smoke_assert_contains "$out" "patch-dev" "T1 refuse message names the configured restart-peer (patch-dev)"
  smoke_assert_eq "" "$(cat "$SIDE_EFFECT_LOG")" "T1 kill never ran with peer set"
}

# T2 — refuse self-restart, peer UNSET → "manually" fallback, kill never ran.
test_refuse_self_peer_unset() {
  : > "$SIDE_EFFECT_LOG"
  local agent="solo-admin"
  local out="" rc=0
  out="$(
    declare -A BRIDGE_AGENT_RESTART_PEER=()
    install_run_restart_stubs
    SCRIPT_DIR="$REPO_ROOT" BRIDGE_BASH_BIN="$(command -v bash)" \
      BRIDGE_AGENT_ID="$agent" BRIDGE_RESTART_DETACHED="" TMUX="" \
      run_restart "$agent" 2>&1
  )" || rc=$?
  smoke_assert_eq "$rc" "1" "T2 refused self-restart (no peer) exits non-zero"
  smoke_assert_contains "$out" "manually" "T2 message falls back to the manual instruction when no peer is set"
  smoke_assert_contains "$out" "BRIDGE_AGENT_RESTART_PEER" "T2 message tells the operator how to configure a peer"
  smoke_assert_eq "" "$(cat "$SIDE_EFFECT_LOG")" "T2 kill never ran with no peer"
}

# T3 — restarting a DIFFERENT agent is unchanged: the guard is NOT taken, the
# path proceeds, and the kill sentinel fires (proving we reached the real kill).
test_allow_other_reaches_kill() {
  : > "$SIDE_EFFECT_LOG"
  local agent="patch"
  local caller="patch-dev"   # a different identity restarting patch (supervised)
  local out="" rc=0
  out="$(
    declare -A BRIDGE_AGENT_RESTART_PEER=()
    install_run_restart_stubs
    SCRIPT_DIR="$REPO_ROOT" BRIDGE_BASH_BIN="$(command -v bash)" \
      BRIDGE_AGENT_ID="$caller" BRIDGE_RESTART_DETACHED="" TMUX="" \
      run_restart "$agent" 2>&1
  )" || rc=$?
  smoke_assert_eq "$rc" "0" "T3 restarting a different agent proceeds (kill sentinel exits 0)"
  smoke_assert_contains "$(cat "$SIDE_EFFECT_LOG")" "KILL patch" "T3 non-self restart REACHED the kill (unchanged path)"
  smoke_assert_not_contains "$out" "cannot restart its own session" "T3 no refuse message for a different caller"
}

# T4 — mutation: revert the guard (strip the caller-identity check) and confirm
# a self-restart PROCEEDS to the kill (the split-brain path), proving T1/T2 are
# non-vacuous and the guard is what holds the line.
test_mutation_without_guard_self_proceeds() {
  : > "$SIDE_EFFECT_LOG"
  local mutated="$SMOKE_TMP_ROOT/run_restart.mutated.sh"
  # Delete the guard block: from the #2051 marker line through its closing `fi`.
  awk '
    /#2051: self-restart split-brain guard/ { drop=1 }
    drop && /bridge_agent_restart_self_refused_guidance/ { drop_die=1 }
    drop && drop_die && /^  fi$/ { drop=0; drop_die=0; next }
    !drop { print }
  ' "$RUN_RESTART_SHIM" > "$mutated"
  # Sanity: the mutation must have actually removed the refuse call.
  if grep -q 'bridge_agent_restart_self_refused_guidance' "$mutated"; then
    smoke_fail "T4 mutation did not strip the guard (refuse call still present)"
  fi
  grep -q '^}$' "$mutated" || smoke_fail "T4 mutated shim is not closed"

  local rc=0
  (
    # Redefine run_restart from the mutated shim inside the subshell.
    # shellcheck source=/dev/null
    source "$mutated"
    install_run_restart_stubs
    SCRIPT_DIR="$REPO_ROOT" BRIDGE_BASH_BIN="$(command -v bash)" \
      BRIDGE_AGENT_ID="patch" BRIDGE_RESTART_DETACHED="" TMUX="" \
      run_restart "patch" >/dev/null 2>&1
  ) || rc=$?
  smoke_assert_eq "$rc" "0" "T4 WITHOUT the guard a self-restart proceeds (kill sentinel exits 0)"
  smoke_assert_contains "$(cat "$SIDE_EFFECT_LOG")" "KILL patch" \
    "T4 WITHOUT the guard the self-restart REACHES the kill — the split-brain path the guard prevents"
}

# T5 — roster map is associative (declare -Ag), no #2020 index-0 collapse, and
# the accessor reads back the configured peer / empty.
test_roster_assoc_no_index0_collapse() {
  (
    bridge_reset_roster_maps
    # shellcheck source=/dev/null
    source "$REPO_ROOT/agent-roster.sh"
    bridge_var_is_assoc BRIDGE_AGENT_RESTART_PEER \
      || smoke_fail "T5 BRIDGE_AGENT_RESTART_PEER is not associative after sourcing the roster"
    # Multi-agent population — the #2020 shape: a non-numeric subscript on a
    # broken indexed array silently collapses to index 0.
    BRIDGE_AGENT_RESTART_PEER["patch"]="patch-dev"
    BRIDGE_AGENT_RESTART_PEER["patch-dev"]="patch"
    BRIDGE_AGENT_RESTART_PEER["alpha"]="beta"
    local n=${#BRIDGE_AGENT_RESTART_PEER[@]}
    [[ "$n" -eq 3 ]] || smoke_fail "T5 expected 3 distinct peers, got $n (index-0 collapse)"
    if printf '%s\n' "${!BRIDGE_AGENT_RESTART_PEER[@]}" | grep -qx '0'; then
      smoke_fail "T5 index-0 key present — map collapsed to an indexed array (#2020)"
    fi
    smoke_assert_eq "patch-dev" "$(bridge_agent_restart_peer patch)" "T5 accessor returns the configured peer"
    smoke_assert_eq "" "$(bridge_agent_restart_peer ghost)" "T5 accessor returns empty for an unconfigured agent"
  )
}

smoke_run "T1 refuse self-restart names the peer + no kill"      test_refuse_self_peer_named
smoke_run "T2 refuse self-restart falls back to manual + no kill" test_refuse_self_peer_unset
smoke_run "T3 restarting a different agent reaches the kill"     test_allow_other_reaches_kill
smoke_run "T4 mutation: without the guard self-restart proceeds" test_mutation_without_guard_self_proceeds
smoke_run "T5 restart-peer roster map assoc, no index-0 collapse" test_roster_assoc_no_index0_collapse

smoke_log "all checks passed"
