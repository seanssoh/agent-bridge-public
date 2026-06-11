#!/usr/bin/env bash
# scripts/smoke/1795-reaper-ephemeral-policy.sh
#
# Issue #1795: the daemon's idle dynamic-agent reaper
# (reap_idle_dynamic_agents in bridge-daemon.sh) reaped ANY roster dynamic that
# was detached + queue-empty + tmux-idle past BRIDGE_DYNAMIC_IDLE_REAP_SECONDS,
# conflating "dynamic" (creation method) with "disposable". That killed
# operator-created long-lived pair agents (4 confirmed live reaps) and even
# loop=1 relaunch agents (voiding the loop contract).
#
# The fix gates the reap on a per-dynamic disposability tag:
#   - ephemeral == "1"  (set ONLY at the throwaway-spawn surfaces via the
#                        `--ephemeral` flag / BRIDGE_AGENT_EPHEMERAL=1)
#   - loop      != "1"  (a relaunch-loop agent is NEVER reaped)
# Absent/legacy/operator-created ⇒ ephemeral reads "0" ⇒ never reaped (the
# indeterminate-is-conservative migration fail-safe).
#
# This smoke SOURCES bridge-daemon.sh into its own shell (the #1679-style
# non-inheritable in-process seam: when BASH_SOURCE != $0 the daemon does NOT
# run the verb dispatch), seeds the in-memory roster maps directly, and stubs
# the tmux / queue / kill helpers the reaper calls so each fixture agent hits a
# deterministic verdict WITHOUT a live tmux server or SQLite queue. A real
# daemon never sources this file, so the stub seam is structurally out of reach
# in production.
#
# Coverage (every fixture is detached + queue-empty + idle past the threshold
# unless its name says otherwise, so ONLY the new disposability policy decides
# the verdict):
#   (a) operator-created dynamic (no ephemeral flag), idle past threshold
#       -> NOT reaped (non-ephemeral default).
#   (b) ephemeral=1 dynamic, idle past threshold
#       -> REAPED (the only reapable class).
#   (c) ephemeral=1 + loop=1, idle past threshold
#       -> NOT reaped (loop wins over ephemeral).
#   (d) ephemeral=1 but NOT idle (idle < threshold)
#       -> NOT reaped (the pre-existing idle predicate is intact).
#   (e) migration: legacy entry whose meta file has NO AGENT_EPHEMERAL line
#       -> reads "0" -> NOT reaped.
#   (f) skip-audit: a `reaper kept idle dynamic ...` line is emitted for the
#       kept-idle cases (a) + (c), and NOT for the reaped case (b).
#   (g) static agents are never even considered (source != dynamic).
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at a python3
# subprocess. The only here-doc is a plain meta-file fixture written to disk.

set -euo pipefail

SMOKE_NAME="1795-reaper-ephemeral-policy"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

# The reaper reads BRIDGE_DYNAMIC_IDLE_REAP_SECONDS; pin a small threshold so the
# fixtures' canned idle values are unambiguous.
export BRIDGE_DYNAMIC_IDLE_REAP_SECONDS=100

# Source the daemon's functions into THIS shell (non-inheritable seam: the verb
# dispatch is gated on BASH_SOURCE == $0, which is false here).
# shellcheck source=bridge-daemon.sh
source "$SMOKE_REPO_ROOT/bridge-daemon.sh"

# --- Deterministic stubs for the reaper's external dependencies -------------
# Per-session canned state, keyed by the fixture session name.
declare -A SESSION_ATTACHED=()
declare -A SESSION_IDLE=()
declare -A SESSION_QUEUE_NONEMPTY=()
# Record of which agents the reaper killed. The reaper is invoked with stdout
# redirected to a file (NOT command substitution) so it runs in THIS shell and
# the kill stub's file append is the cross-call record. A `$()` capture would
# fork a subshell and the kill record would not survive.
KILLED_FILE="$SMOKE_TMP_ROOT/killed.txt"
: >"$KILLED_FILE"

# Every fixture's session "exists" for the purposes of this smoke.
bridge_tmux_session_exists() { return 0; }

bridge_tmux_session_attached_count() {
  local session="$1"
  printf '%s' "${SESSION_ATTACHED[$session]-0}"
}

bridge_tmux_session_idle_seconds() {
  local session="$1"
  printf '%s' "${SESSION_IDLE[$session]-0}"
}

# Mimic `bridge_queue_cli summary --agent <a> --format tsv` shape: the reaper
# reads queued/claimed/blocked from columns 2-4 (column 1 is the agent id). We
# only need to drive the "has open work" branch, so emit one nonzero queued
# count when the fixture asks for it.
bridge_queue_cli() {
  # args: summary --agent <agent> --format tsv
  local agent=""
  local prev=""
  local a
  for a in "$@"; do
    [[ "$prev" == "--agent" ]] && agent="$a"
    prev="$a"
  done
  if [[ "${SESSION_QUEUE_NONEMPTY[$agent]-0}" == "1" ]]; then
    printf '%s\t1\t0\t0\n' "$agent"
  else
    printf '%s\t0\t0\t0\n' "$agent"
  fi
}

# Capture-and-succeed kill so the reaper proceeds to remove the roster entry.
bridge_kill_agent_session() {
  local agent="$1"
  printf '%s\n' "$agent" >>"$KILLED_FILE"
  return 0
}

# Was <agent> killed in the most recent reaper run? (reads the record file)
was_killed() {
  local agent="$1"
  grep -qxF "$agent" "$KILLED_FILE" 2>/dev/null
}

# The archive/remove side-effects touch the on-disk meta tree; make them no-ops
# so the assertion is purely "did the reaper decide to kill this agent".
bridge_archive_dynamic_agent() { return 0; }
bridge_remove_dynamic_agent_file() { return 0; }

# --- Roster fixtures --------------------------------------------------------
# Reset the roster maps to a clean associative state, then register fixtures.
bridge_reset_roster_maps

# register_dynamic <agent> <ephemeral> <loop> <attached> <idle> <queue_nonempty>
register_dynamic() {
  local agent="$1" ephemeral="$2" loop="$3" attached="$4" idle="$5" qne="$6"
  bridge_add_agent_id_if_missing "$agent"
  BRIDGE_AGENT_SOURCE["$agent"]="dynamic"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_LOOP["$agent"]="$loop"
  BRIDGE_AGENT_EPHEMERAL["$agent"]="$ephemeral"
  SESSION_ATTACHED["$agent"]="$attached"
  SESSION_IDLE["$agent"]="$idle"
  SESSION_QUEUE_NONEMPTY["$agent"]="$qne"
}

IDLE_PAST=200   # > threshold (100)
IDLE_FRESH=10   # < threshold

# (a) operator-created: ephemeral=0, loop=0, idle past threshold -> KEEP
register_dynamic op-pair 0 0 0 "$IDLE_PAST" 0
# (b) ephemeral worker: ephemeral=1, loop=0, idle past threshold -> REAP
register_dynamic wave-fixer 1 0 0 "$IDLE_PAST" 0
# (c) ephemeral + loop: ephemeral=1, loop=1, idle past threshold -> KEEP
register_dynamic loop-worker 1 1 0 "$IDLE_PAST" 0
# (d) ephemeral but fresh: ephemeral=1, loop=0, idle BELOW threshold -> KEEP
register_dynamic fresh-worker 1 0 0 "$IDLE_FRESH" 0

# (g) a static agent that must never be considered.
bridge_add_agent_id_if_missing static-admin
BRIDGE_AGENT_SOURCE["static-admin"]="static"
BRIDGE_AGENT_SESSION["static-admin"]="static-admin"
BRIDGE_AGENT_LOOP["static-admin"]="1"
SESSION_ATTACHED["static-admin"]=0
SESSION_IDLE["static-admin"]="$IDLE_PAST"
SESSION_QUEUE_NONEMPTY["static-admin"]=0

# (e) migration fixture: a legacy meta env file with NO AGENT_EPHEMERAL line.
# Load it through the real loader so the migration default ("0") is exercised
# end-to-end, not hand-set. The loader gates SESSION_ID hydration through the
# resume resolver; stub it to keep the load self-contained.
bridge_resolve_resume_session_id() { printf ''; return 1; }
LEGACY_FILE="$BRIDGE_ACTIVE_AGENT_DIR/legacy-pair.env" # noqa: iso-helper-boundary — test fixture in this smoke's isolated mktemp BRIDGE_HOME, not a controller->iso credential dotenv
cat >"$LEGACY_FILE" <<EOF
AGENT_ID=legacy-pair
AGENT_DESC=legacy-pair
AGENT_ENGINE=codex
AGENT_SESSION=legacy-pair
AGENT_WORKDIR=$BRIDGE_HOME
AGENT_LOOP=0
AGENT_CONTINUE=1
AGENT_SESSION_ID=
AGENT_HISTORY_KEY=
AGENT_CREATED_AT=
AGENT_UPDATED_AT=
EOF
bridge_load_dynamic_agent_file "$LEGACY_FILE"
# Sanity: the migration default must read non-ephemeral.
smoke_assert_eq "0" "$(bridge_agent_ephemeral legacy-pair)" \
  "(e) legacy entry without AGENT_EPHEMERAL must read non-ephemeral"
SESSION_ATTACHED["legacy-pair"]=0
SESSION_IDLE["legacy-pair"]="$IDLE_PAST"
SESSION_QUEUE_NONEMPTY["legacy-pair"]=0

# Writer->loader roundtrip: an ephemeral=1 dynamic must persist AGENT_EPHEMERAL
# in its meta file and read back as "1" through the real writer + loader (the
# plumbing the daemon relies on across sync cycles). wave-fixer is already
# registered with ephemeral=1 in memory; flush it to disk and reload.
ROUNDTRIP_FILE="$BRIDGE_ACTIVE_AGENT_DIR/wave-fixer.env" # noqa: iso-helper-boundary — test fixture in this smoke's isolated mktemp BRIDGE_HOME, not a controller->iso credential dotenv
bridge_write_agent_state_file wave-fixer "$ROUNDTRIP_FILE"
grep -q '^AGENT_EPHEMERAL=' "$ROUNDTRIP_FILE" \
  || smoke_fail "writer did not persist AGENT_EPHEMERAL for an ephemeral dynamic"
# Reload the just-written file and confirm the tag survives the load.
bridge_load_dynamic_agent_file "$ROUNDTRIP_FILE"
smoke_assert_eq "1" "$(bridge_agent_ephemeral wave-fixer)" \
  "ephemeral=1 must round-trip through write -> load"

# --- Act --------------------------------------------------------------------
# Run the reaper IN THIS SHELL (no `$()` subshell) so the kill-record file
# append survives; tee daemon_info stdout into a capture file for the audit
# assertions.
REAP_LOG="$SMOKE_TMP_ROOT/reap.log"
reap_idle_dynamic_agents >"$REAP_LOG" 2>&1 || true
REAP_OUT="$(cat "$REAP_LOG")"

smoke_log "reaper output:"
sed 's/^/    /' "$REAP_LOG"

# --- Assertions -------------------------------------------------------------
# (b) the ONLY agent that should have been killed is the ephemeral non-loop one.
was_killed wave-fixer \
  || smoke_fail "(b) ephemeral non-loop idle worker was NOT reaped"

# (a)/(c)/(d)/(e)/(g) must all survive.
! was_killed op-pair \
  || smoke_fail "(a) operator-created dynamic was reaped — must never be reaped"
! was_killed loop-worker \
  || smoke_fail "(c) ephemeral+loop=1 agent was reaped — loop must win"
! was_killed fresh-worker \
  || smoke_fail "(d) ephemeral but not-yet-idle worker was reaped — idle predicate broken"
! was_killed legacy-pair \
  || smoke_fail "(e) legacy (no-flag) dynamic was reaped — migration fail-safe broken"
! was_killed static-admin \
  || smoke_fail "(g) a static agent was reaped — reaper must only touch dynamics"

# Exactly one kill total.
killed_total="$(grep -c . "$KILLED_FILE" 2>/dev/null)" || killed_total=0
smoke_assert_eq "1" "$killed_total" "exactly one ephemeral non-loop agent reaped"

# (f) skip-audit lines for the kept-idle cases, and the reaped line for (b).
smoke_assert_contains "$REAP_OUT" "reaper kept idle dynamic op-pair" \
  "(f) skip-audit for the operator-created kept-idle case"
smoke_assert_contains "$REAP_OUT" "non-ephemeral operator-created" \
  "(f) skip-audit reason names the non-ephemeral cause"
smoke_assert_contains "$REAP_OUT" "reaper kept idle dynamic loop-worker" \
  "(f) skip-audit for the loop=1 kept-idle case"
smoke_assert_contains "$REAP_OUT" "loop=1 relaunch agent" \
  "(f) skip-audit reason names the loop cause"
smoke_assert_contains "$REAP_OUT" "reaped dynamic wave-fixer" \
  "(f) reap audit emitted for the ephemeral worker"
# The kept agents must NOT show up as reaped.
smoke_assert_not_contains "$REAP_OUT" "reaped dynamic op-pair" \
  "(f) operator-created dynamic must not appear in a reap line"
smoke_assert_not_contains "$REAP_OUT" "reaped dynamic loop-worker" \
  "(f) loop agent must not appear in a reap line"

# --- Disable knob: threshold=0 short-circuits the whole reaper ---------------
: >"$KILLED_FILE"
BRIDGE_DYNAMIC_IDLE_REAP_SECONDS=0 reap_idle_dynamic_agents >/dev/null 2>&1 || true
killed_total="$(grep -c . "$KILLED_FILE" 2>/dev/null)" || killed_total=0
smoke_assert_eq "0" "$killed_total" \
  "BRIDGE_DYNAMIC_IDLE_REAP_SECONDS=0 must disable the reaper entirely"

# --- In-source wiring guard -------------------------------------------------
# The reap predicate must gate on the explicit ephemeral=="1" + loop!="1"
# conditions; a refactor that drops either re-opens the #1795 footgun.
DAEMON_SRC="$SMOKE_REPO_ROOT/bridge-daemon.sh"
grep -q 'bridge_agent_ephemeral "\$agent"' "$DAEMON_SRC" \
  || smoke_fail "S1: reaper no longer reads bridge_agent_ephemeral"
grep -q 'reaper kept idle dynamic' "$DAEMON_SRC" \
  || smoke_fail "S2: reaper skip-audit line missing"

smoke_log "PASS"
