#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1378-iso-session-lock-fresh-start.sh — Issue #1378.
#
# v0.15.0-beta5-4 — Track N. Fresh iso v2 agent start failed with
# `lib/bridge-state.sh: <BRIDGE_HOME>/data/agents/<a>/runtime/session.lock:
# Permission denied` — an OOTB BLOCKER on a clean Linux install, found by
# patch's v0.15.0-beta5-3 fresh-install acceptance verify
# (cm-prod-agentworkflow-vm01).
#
# Root cause (same controller-stale-group class as Issue #1025):
#   - bridge_agent_session_lock_file resolved its path via
#     bridge_agent_runtime_state_dir, which for iso-v2 agents diverts into
#     the iso DATA tree data/agents/<a>/runtime/ — a leaf owned by
#     root:ab-agent-<a> at mode 2770, NOT owned by the controller.
#   - bridge_persist_agent_state opens that lock as the controller via
#     `} 9>"$_lock_file"`. The controller IS added to ab-agent-<a> at
#     prepare, but `usermod -aG` does not refresh the running controller/
#     daemon process's supplementary-group set (documented
#     lib/bridge-agents.sh:3422-3434, Issue #1025), so for a freshly-created
#     iso agent the controller can neither traverse the 2750 parent nor
#     open the 2770 root-owned lock until a re-login / daemon group-refresh.
#   - Existing iso agents (restart) were unaffected — their lock pre-existed
#     controller-writable from an earlier install.
#
# Fix (preferred, per the issue's fix direction): the session.lock is a
# CONTROLLER-ONLY serialisation primitive — the agent UID never flocks it
# (the only consumers are bridge_persist_agent_state and
# bridge_clear_persisted_session_id, both controller-side). So
# bridge_agent_session_lock_file now anchors on the CONTROLLER-OWNED state
# leaf (bridge_agent_idle_marker_dir → state/agents/<a>/, owner=controller
# mode 2770) — the path its own docstring already named — instead of the
# iso data tree. The controller-owned leaf has controller OWNER rwx, so the
# controller can always create + flock it regardless of its live group set.
# For non-iso/shared agents this is a no-op: bridge_agent_runtime_state_dir
# already returns bridge_agent_idle_marker_dir there.
#
# Test plan (all assertions are PATH RESOLUTION + permission LOGIC, made
# deterministic without real sudo/groups — the REAL Linux-host acceptance
# is patch's fresh-install re-verify; the macOS smoke proves the resolution
# + the denial-vs-success delta):
#   T1 (iso path resolution): with iso-v2 active (harness default), assert
#       bridge_agent_session_lock_file resolves under the controller-owned
#       state leaf (state/agents/<a>/) and NOT under the iso data tree
#       (data/agents/<a>/runtime/).
#   T2 (regression — shared/non-iso byte-identical): with iso-v2 NOT active,
#       assert the lock path is byte-identical to the legacy resolution
#       (bridge_agent_runtime_state_dir == bridge_agent_idle_marker_dir),
#       i.e. zero behaviour change for shared/legacy mode.
#   T3 (permission delta — the OOTB repro with teeth): build a controller-
#       writable state leaf AND a controller-UNwritable simulated root-owned
#       data-tree leaf (chmod 0500). Assert taking the lock at the FIXED
#       (state-leaf) path succeeds, while taking it at the data-tree path
#       hits Permission denied. This is the deterministic stand-in for the
#       fresh-iso stale-group denial.
#   T4 (grep teeth): assert bridge_agent_session_lock_file references
#       bridge_agent_idle_marker_dir and does NOT reference
#       bridge_agent_runtime_state_dir, pinning the fix so a future refactor
#       that reverts the anchor back to the iso data tree fails loudly.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses no command
# substitution feeding a heredoc stdin and no `<<<` here-strings into bridge
# functions; lock-take probes run flock against a real fd opened on a file.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays. macOS ships /bin/bash 3.2 —
# match the recipe used by other smokes.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1378-iso-session-lock-fresh-start] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1378-iso-session-lock-fresh-start"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1378-iso-session-lock-fresh-start"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Source the library functions under test.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

# Sanity checks.
if ! declare -F bridge_agent_session_lock_file >/dev/null; then
  smoke_fail "bridge_agent_session_lock_file not defined after sourcing bridge-lib.sh"
fi
if ! declare -F bridge_agent_idle_marker_dir >/dev/null; then
  smoke_fail "bridge_agent_idle_marker_dir not defined (sanity check)"
fi
if ! declare -F bridge_agent_runtime_state_dir >/dev/null; then
  smoke_fail "bridge_agent_runtime_state_dir not defined (sanity check)"
fi
if ! declare -F bridge_isolation_v2_active >/dev/null; then
  smoke_fail "bridge_isolation_v2_active not defined (sanity check)"
fi

STATE_LIB="$REPO_ROOT/lib/bridge-state.sh"
AGENT="isofresh"

# ---------------------------------------------------------------------
# T1 — iso path resolution: lock anchors on the controller-owned state
# leaf, NOT the iso data tree.
# ---------------------------------------------------------------------
test_iso_lock_resolves_to_controller_state_leaf() {
  smoke_log "T1: iso-v2 lock path resolves to controller-owned state leaf"

  # Harness default is v2-active (BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT set).
  if ! bridge_isolation_v2_active; then
    smoke_fail "T1: precondition failed — iso-v2 not active in harness (BRIDGE_LAYOUT='$BRIDGE_LAYOUT' BRIDGE_DATA_ROOT='${BRIDGE_DATA_ROOT:-}')"
  fi

  local lock_path state_leaf data_tree
  lock_path="$(bridge_agent_session_lock_file "$AGENT")"
  state_leaf="$(bridge_agent_idle_marker_dir "$AGENT")"
  data_tree="$(bridge_agent_runtime_state_dir "$AGENT")"

  smoke_log "T1: lock_path=$lock_path"
  smoke_log "T1: state_leaf=$state_leaf  data_tree=$data_tree"

  # Sanity — the two trees must be genuinely distinct under iso-v2, else
  # the test proves nothing.
  if [[ "$state_leaf" == "$data_tree" ]]; then
    smoke_fail "T1: harness invariant broken — state leaf == data tree under iso-v2 ($state_leaf); cannot distinguish the fix"
  fi

  smoke_assert_eq "$state_leaf/session.lock" "$lock_path" \
    "T1: lock must anchor on controller-owned state leaf"
  smoke_assert_contains "$lock_path" "$BRIDGE_ACTIVE_AGENT_DIR/" \
    "T1: lock path under BRIDGE_ACTIVE_AGENT_DIR (state/agents)"
  smoke_assert_not_contains "$lock_path" "$data_tree" \
    "T1: lock path MUST NOT live in the iso data tree (data/agents/<a>/runtime)"
  smoke_assert_not_contains "$lock_path" "/runtime/" \
    "T1: lock path MUST NOT be under the iso runtime subtree"
}

# ---------------------------------------------------------------------
# T2 — regression: shared/non-iso lock path byte-identical to the legacy
# resolution (zero behaviour change off the iso path).
# ---------------------------------------------------------------------
test_shared_lock_path_byte_identical() {
  smoke_log "T2: shared/non-iso lock path byte-identical to legacy resolution"

  # Flip iso-v2 OFF for this probe by clearing BRIDGE_LAYOUT in a subshell-
  # scoped override. bridge_isolation_v2_active returns 1 when
  # BRIDGE_LAYOUT != v2, and bridge_agent_runtime_state_dir then falls back
  # to bridge_agent_idle_marker_dir — exactly the path the fix uses.
  local lock_path runtime_dir idle_dir
  (
    BRIDGE_LAYOUT="v1"
    if bridge_isolation_v2_active; then
      smoke_fail "T2: precondition failed — iso-v2 still active after BRIDGE_LAYOUT=v1"
    fi
    lock_path="$(bridge_agent_session_lock_file "$AGENT")"
    runtime_dir="$(bridge_agent_runtime_state_dir "$AGENT")"
    idle_dir="$(bridge_agent_idle_marker_dir "$AGENT")"

    smoke_log "T2: lock_path=$lock_path"
    smoke_log "T2: runtime_dir=$runtime_dir  idle_dir=$idle_dir"

    # Off the iso path, runtime_dir IS idle_dir — the lock path must equal
    # the legacy `runtime_dir/session.lock` byte for byte.
    smoke_assert_eq "$runtime_dir" "$idle_dir" \
      "T2: non-iso runtime_dir must equal idle_dir (legacy invariant)"
    smoke_assert_eq "$runtime_dir/session.lock" "$lock_path" \
      "T2: non-iso lock path byte-identical to legacy runtime_dir/session.lock"
  )
}

# ---------------------------------------------------------------------
# T3 — permission delta with teeth: the lock take SUCCEEDS at the
# controller-owned state leaf and FAILS (Permission denied) at the
# simulated root-owned data-tree leaf. Deterministic stand-in for the
# fresh-iso stale-group denial, no real sudo/groups required.
# ---------------------------------------------------------------------
test_lock_take_permission_delta() {
  smoke_log "T3: lock-take permission delta — state leaf OK, data tree denied"

  # The OOTB denial is at the `} 9>"$_lock_file"` OPEN of the lock file,
  # not at the `flock` call — so we probe the fd-open directly (the exact
  # shape bridge_persist_agent_state / bridge_clear_persisted_session_id
  # use). This is independent of whether `flock(1)` exists on the host, so
  # the permission delta runs with teeth even on macOS hosts that lack
  # flock (where the production code uses its mkdir-based fallback).

  # Build the controller-owned state leaf (writable) — this is where the
  # FIXED helper resolves the lock.
  local state_leaf data_tree
  state_leaf="$(bridge_agent_idle_marker_dir "$AGENT")"
  data_tree="$(bridge_agent_runtime_state_dir "$AGENT")"
  mkdir -p "$state_leaf"
  chmod 0770 "$state_leaf"

  # Build the simulated controller-UNwritable iso-data-tree leaf. On the
  # real host the controller is NOT the owner of data/agents/<a>/runtime/
  # (group=ab-agent-<a> 2770, under a 2750 root:ab-agent-<a> per-agent
  # root) and its stale supplementary-group set means the group bits do
  # not help — so it cannot create the lock there. We stand that in with
  # mode 0500 (r-x------): the *current* (controller) UID cannot create a
  # file inside it, deterministically, without any real sudo/groups.
  mkdir -p "$data_tree"
  chmod 0500 "$data_tree"

  # --- FIXED helper: lock resolves to the writable state leaf → open succeeds.
  local fixed_lock fixed_rc=0
  fixed_lock="$(bridge_agent_session_lock_file "$AGENT")"
  smoke_assert_eq "$state_leaf/session.lock" "$fixed_lock" \
    "T3: fixed helper resolves lock to the controller-owned state leaf"
  if ( exec 9>"$fixed_lock" ) 2>/dev/null; then
    smoke_log "T3: lock-open at fixed (state-leaf) path succeeded"
  else
    fixed_rc=$?
    smoke_fail "T3: lock-open at the controller-owned state leaf FAILED (rc=$fixed_rc) — fix is broken"
  fi
  smoke_assert_file_exists "$fixed_lock" "T3: lock file created at state leaf"

  # --- TEETH: revert to the pre-fix anchor (data tree) and prove the
  # denial reproduces. We open an fd directly on the data-tree lock path,
  # the exact `9>"$_lock_file"` shape bridge_persist_agent_state uses.
  local data_lock denial_seen=0
  data_lock="$data_tree/session.lock"
  smoke_log "T3 (teeth): attempting lock open at pre-fix data-tree path: $data_lock"
  if ( exec 9>"$data_lock" ) 2>/dev/null; then
    # If this somehow succeeds the chmod 0500 simulation did not hold (e.g.
    # the test is running as root, which can write through mode bits). Skip
    # the teeth assertion in that case rather than false-fail.
    if [[ "$(id -u)" == "0" ]]; then
      smoke_skip "T3 teeth" "running as root — mode 0500 does not deny root; denial repro only meaningful as non-root"
    else
      smoke_fail "T3 (teeth): lock open at data-tree path UNEXPECTEDLY succeeded — chmod 0500 stand-in did not deny the controller UID"
    fi
  else
    denial_seen=1
    smoke_log "T3 (teeth): pre-fix data-tree lock open denied as expected"
  fi

  if [[ "$(id -u)" != "0" ]]; then
    smoke_assert_eq "1" "$denial_seen" \
      "T3 (teeth): pre-fix data-tree path must reproduce the Permission denied"
    # And the data-tree lock file must NOT have been created (denial).
    if [[ -f "$data_lock" ]]; then
      smoke_fail "T3 (teeth): data-tree lock file was created despite mode 0500 — denial stand-in invalid"
    fi
  fi

  # Restore mode so cleanup can rm -rf the tree.
  chmod 0700 "$data_tree" 2>/dev/null || true
}

# ---------------------------------------------------------------------
# T4 — grep teeth: pin the helper to the controller-owned anchor so a
# future refactor cannot silently revert it to the iso data tree.
# ---------------------------------------------------------------------
test_helper_anchors_on_controller_state_leaf() {
  smoke_log "T4: grep teeth — helper anchors on bridge_agent_idle_marker_dir"

  smoke_assert_file_exists "$STATE_LIB" "T4: bridge-state.sh exists"

  # Capture the helper body: from its signature line to the closing brace.
  local body
  body="$(awk '
    /^bridge_agent_session_lock_file\(\)[ \t]*\{/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "$STATE_LIB")"

  if [[ -z "$body" ]]; then
    smoke_fail "T4: could not isolate bridge_agent_session_lock_file body in $STATE_LIB"
  fi

  smoke_assert_contains "$body" "bridge_agent_idle_marker_dir" \
    "T4: helper must resolve via bridge_agent_idle_marker_dir (controller-owned state leaf)"
  smoke_assert_not_contains "$body" "bridge_agent_runtime_state_dir" \
    "T4 (teeth): helper MUST NOT resolve via bridge_agent_runtime_state_dir (iso data tree) — #1378 regression"
}

smoke_run "T1 iso lock → controller state leaf" test_iso_lock_resolves_to_controller_state_leaf
smoke_run "T2 shared lock byte-identical" test_shared_lock_path_byte_identical
smoke_run "T3 lock-take permission delta" test_lock_take_permission_delta
smoke_run "T4 grep teeth" test_helper_anchors_on_controller_state_leaf

smoke_log "PASS — #1378 iso session.lock anchored on controller-owned state leaf; shared path unchanged; denial repro proven"
