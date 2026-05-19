#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/981-restart-session-resume-snapshot.sh — Issue #981.
#
# Pins the snapshot+restore contract that `run_restart`
# (bridge-agent.sh:4156) uses to keep a Claude conversation resumable
# across an operator-initiated `agent restart`. Without this contract,
# `bridge_kill_agent_session` issues a SIGKILL that interrupts Claude's
# transcript flush; the new `bridge-start.sh` subprocess then re-runs
# the resolver gate on the persisted session_id, and certain
# transcript-truncation paths cause it to wipe the id — the next launch
# starts a fresh conversation instead of `--resume <previous-id>`.
#
# The fix introduced in this PR:
#   1. `bridge_set_agent_session_id` — symmetric inverse of
#      `bridge_clear_agent_session_id`. Writes BRIDGE_AGENT_SESSION_ID
#      + persists to disk in one shot.
#   2. `run_restart` snapshots the live session_id before each call to
#      `bridge_kill_agent_session` and re-injects it after the kill via
#      the new setter.
#
# Test plan (all run against the bash helpers, no live tmux):
#   T1. `bridge_set_agent_session_id` sets the in-memory map AND writes
#       through to the persisted state file (the inverse path that
#       `bridge_clear_agent_session_id` already covers).
#   T2. Empty session_id is rejected (the setter is for snapshot
#       restore — explicit clearing must go through the dedicated
#       clear helper so the intent is obvious at the call site).
#   T3. The snapshot+kill+restore sequence that run_restart performs
#       leaves the in-memory map AND the persisted state file with the
#       original session_id, even when the kill is simulated as a wipe.
#       This is the actual regression vector: prior to the fix, an
#       intervening wipe between the snapshot read and the next launch
#       command build would erase the id; the snapshot+restore now
#       restores it.
#   T4. `bridge_set_agent_session_id` is wired to `bridge_persist_agent_
#       state` so a real disk write happens (regression vector for a
#       hypothetical future change that forgets the persist step).
#
# Isolation: temp BRIDGE_HOME with v2 layout via smoke_setup_bridge_home;
# the smoke never reads or writes the operator's live runtime.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `printf '%s\n' >$tmp` and `cat >file <<EOF` plain bodies on flat
# string variables — no command substitution feeding a heredoc-stdin,
# no `<<<` here-strings into bridge functions. See
# `memory/feedback_bash_heredoc_write_class_recurrence.md`.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays. macOS ships /bin/bash
# 3.2 — match the recipe used by scripts/smoke/bridge-sync-roster-memo.sh.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:981-restart-session-resume-snapshot] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="981-restart-session-resume-snapshot"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "981-restart-session-resume-snapshot"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Source the library functions under test. bridge-lib.sh transitively
# sources lib/bridge-state.sh (where bridge_set_agent_session_id lives)
# and lib/bridge-agents.sh (where bridge_agent_session_id reads back).
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

if ! declare -F bridge_set_agent_session_id >/dev/null; then
  smoke_fail "bridge_set_agent_session_id not defined after sourcing bridge-lib.sh"
fi
if ! declare -F bridge_clear_agent_session_id >/dev/null; then
  smoke_fail "bridge_clear_agent_session_id not defined (sanity check)"
fi
if ! declare -F bridge_agent_session_id >/dev/null; then
  smoke_fail "bridge_agent_session_id not defined (sanity check)"
fi
if ! declare -F bridge_persist_agent_state >/dev/null; then
  smoke_fail "bridge_persist_agent_state not defined (sanity check)"
fi
if ! declare -F bridge_reset_roster_maps >/dev/null; then
  smoke_fail "bridge_reset_roster_maps not defined (sanity check)"
fi

# Initialise the BRIDGE_AGENT_* associative arrays so the test can
# populate them directly without going through bridge_load_roster
# (no roster file on disk for this smoke).
bridge_reset_roster_maps

# Seed a minimal in-memory agent record. We do NOT load a full roster
# from disk — the function under test only touches BRIDGE_AGENT_SESSION_ID
# and the per-agent state file. The other BRIDGE_AGENT_* maps need just
# enough population to satisfy bridge_persist_agent_state's reads
# (engine / workdir / session name / source).
declare -g AGENT_ID="rsr-981"
declare -g WORKDIR
WORKDIR="$SMOKE_TMP_ROOT/work-$AGENT_ID"
mkdir -p "$WORKDIR"

# Seed all the maps bridge_write_agent_state_file reads from. Mirrors
# the shape a real static agent has after bridge_load_roster.
BRIDGE_AGENT_IDS=("$AGENT_ID")
BRIDGE_AGENT_DESC["$AGENT_ID"]="$AGENT_ID smoke fixture"
BRIDGE_AGENT_ENGINE["$AGENT_ID"]="claude"
BRIDGE_AGENT_SESSION["$AGENT_ID"]="$AGENT_ID"
BRIDGE_AGENT_WORKDIR["$AGENT_ID"]="$WORKDIR"
BRIDGE_AGENT_LOOP["$AGENT_ID"]="1"
BRIDGE_AGENT_CONTINUE["$AGENT_ID"]="1"
BRIDGE_AGENT_SOURCE["$AGENT_ID"]="static"
BRIDGE_AGENT_HISTORY_KEY["$AGENT_ID"]="$(bridge_history_key_for claude "$AGENT_ID" "$WORKDIR")"
BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]="$(date +%s)"
BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]=""

# v2 layout: history.env lives under BRIDGE_AGENT_ROOT_V2/<agent>/runtime/.
# bridge_history_file_for builds the path; pre-create the parent dir so
# bridge_write_agent_state_file's mkdir -p does not need to climb past
# any non-writable ancestor.
HISTORY_FILE="$(bridge_history_file_for_agent "$AGENT_ID")"
mkdir -p "$(dirname "$HISTORY_FILE")"

# Stub bridge_state_v2_isolated_target so the smoke does not try the
# sudo-handoff write path (which fails outside a Linux v2 isolated UID).
bridge_state_v2_isolated_target() {
  return 1
}

# T1 — bridge_set_agent_session_id writes through to the in-memory map
# AND the persisted state file.
test_setter_writes_through() {
  local sid="sid-T1-$$"

  BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]=""
  rm -f "$HISTORY_FILE"

  bridge_set_agent_session_id "$AGENT_ID" "$sid"

  smoke_assert_eq "$sid" "${BRIDGE_AGENT_SESSION_ID[$AGENT_ID]}" \
    "T1 in-memory BRIDGE_AGENT_SESSION_ID was set"
  smoke_assert_eq "$sid" "$(bridge_agent_session_id "$AGENT_ID")" \
    "T1 getter returns the snapshot value"
  smoke_assert_file_exists "$HISTORY_FILE" \
    "T1 setter persisted history env file to disk"

  # Read the persisted value via the source-of-truth helper so we are
  # not just reading our own in-memory map back to ourselves.
  local persisted=""
  persisted="$(bridge_agent_persisted_session_id "$AGENT_ID")"
  smoke_assert_eq "$sid" "$persisted" \
    "T1 persisted session id matches snapshot on disk"
}

# T2 — empty session_id is rejected so callers that truly want to wipe
# go through bridge_clear_agent_session_id explicitly.
test_setter_rejects_empty() {
  local sid="sid-T2-$$"
  local rc=0

  BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="$sid"
  bridge_persist_agent_state "$AGENT_ID"

  set +e
  bridge_set_agent_session_id "$AGENT_ID" ""
  rc=$?
  set -e

  smoke_assert_eq "1" "$rc" \
    "T2 empty session_id returns rc=1"
  smoke_assert_eq "$sid" "${BRIDGE_AGENT_SESSION_ID[$AGENT_ID]}" \
    "T2 in-memory map preserved after rejected empty set"
  smoke_assert_eq "$sid" "$(bridge_agent_persisted_session_id "$AGENT_ID")" \
    "T2 persisted value preserved after rejected empty set"
}

# T3 — the snapshot+kill+restore sequence (the actual run_restart
# regression vector). Simulates the kill path wiping the in-memory
# state, then asserts that the snapshot taken BEFORE the wipe is
# restored intact by bridge_set_agent_session_id AFTER the wipe.
#
# This is the heart of the issue: run_restart calls
# bridge_kill_agent_session, and downstream paths (the new bash
# subprocess re-hydrating from disk + bridge_normalize_agent_session_id
# rejecting a transcript that was truncated by the SIGKILL) can wipe
# the persisted session_id. Snapshotting before the kill and restoring
# after guarantees the next launch attempt sees `--resume <prev-id>`.
test_snapshot_restore_round_trip() {
  local sid="sid-T3-$$"

  # Pre-condition: agent has a known session_id, both in memory and on disk.
  bridge_set_agent_session_id "$AGENT_ID" "$sid"
  smoke_assert_eq "$sid" "$(bridge_agent_session_id "$AGENT_ID")" \
    "T3 pre-state: session_id is set"

  # Mirror run_restart line 4233-4239 exactly:
  #   resume_session_snapshot="$(bridge_agent_session_id "$agent" ...)"
  #   bridge_kill_agent_session "$agent"   # (simulated as a wipe)
  #   bridge_set_agent_session_id "$agent" "$resume_session_snapshot"
  local resume_session_snapshot=""
  resume_session_snapshot="$(bridge_agent_session_id "$AGENT_ID")"
  smoke_assert_eq "$sid" "$resume_session_snapshot" \
    "T3 snapshot captures the live session_id before the kill"

  # Simulate the worst-case wipe: bridge_clear_agent_session_id has
  # been called somewhere in the kill→sync→hydrate chain. This is the
  # vector the operator observed in #981 — the post-kill resolver
  # rejected the id and bridge_clear_agent_session_id wiped both the
  # in-memory map and the disk file.
  bridge_clear_agent_session_id "$AGENT_ID"
  smoke_assert_eq "" "$(bridge_agent_session_id "$AGENT_ID")" \
    "T3 simulated wipe cleared the in-memory map"
  smoke_assert_eq "" "$(bridge_agent_persisted_session_id "$AGENT_ID")" \
    "T3 simulated wipe cleared the persisted value"

  # The fix: restore from snapshot.
  if [[ -n "$resume_session_snapshot" ]]; then
    bridge_set_agent_session_id "$AGENT_ID" "$resume_session_snapshot"
  fi

  # Post-condition: the in-memory map AND the persisted state file are
  # both back to the original session_id. The next bridge-start.sh
  # subprocess will read this from disk and build a `--resume <sid>`
  # launch command.
  smoke_assert_eq "$sid" "$(bridge_agent_session_id "$AGENT_ID")" \
    "T3 restore re-populated in-memory map"
  smoke_assert_eq "$sid" "$(bridge_agent_persisted_session_id "$AGENT_ID")" \
    "T3 restore re-persisted to disk for the next subprocess"
}

# T4 — bridge_set_agent_session_id calls bridge_persist_agent_state.
# Regression guard for a future refactor that forgets to persist:
# replace the persister with a spy, then assert the setter invoked it.
test_setter_invokes_persist() {
  local sid="sid-T4-$$"
  local spy_marker="$SMOKE_TMP_ROOT/persist-spy.$$"
  rm -f "$spy_marker"

  # Shadow the persister with a spy. Save the original so we can restore.
  eval "$(declare -f bridge_persist_agent_state | sed '1s/^/_orig_/')"

  # shellcheck disable=SC2329  # invoked indirectly via bridge_set_agent_session_id
  bridge_persist_agent_state() {
    printf '%s\n' "$1" >>"$spy_marker"
    return 0
  }

  bridge_set_agent_session_id "$AGENT_ID" "$sid"

  # Restore the real persister so subsequent tests are not contaminated.
  eval "$(declare -f _orig_bridge_persist_agent_state | sed 's/^_orig_//')"
  unset -f _orig_bridge_persist_agent_state 2>/dev/null || true

  smoke_assert_file_exists "$spy_marker" \
    "T4 spy file exists ⇒ bridge_persist_agent_state was invoked"
  local seen=""
  seen="$(head -n 1 "$spy_marker" 2>/dev/null || true)"
  smoke_assert_eq "$AGENT_ID" "$seen" \
    "T4 persister invoked with the correct agent id"
}

smoke_run "T1 setter writes through to memory + disk"      test_setter_writes_through
smoke_run "T2 setter rejects empty session_id"             test_setter_rejects_empty
smoke_run "T3 snapshot+kill+restore round-trip"            test_snapshot_restore_round_trip
smoke_run "T4 setter invokes bridge_persist_agent_state"   test_setter_invokes_persist

smoke_log "all checks passed"
