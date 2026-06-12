#!/usr/bin/env bash
# scripts/smoke/1797-reaper-keep-audit-latch.sh
#
# Issue #1797 NB-1: the daemon's idle dynamic-agent reaper
# (reap_idle_dynamic_agents in bridge-daemon.sh) emitted a
# `reaper kept idle dynamic <a> (...)` audit line for every idle-but-spared
# dynamic on EVERY tick. patch gate-2 measured ~1.2k lines/day for a single idle
# operator pair; on a multi-agent install that is meaningful log noise.
#
# The fix latches the keep-audit per-agent on a stable keep-reason token
# ("loop" / "non-ephemeral") persisted under
# $BRIDGE_STATE_DIR/reaper-keep-audit/<agent>. The line is emitted only when the
# decision TRANSITIONS (no prior token -> first kept, or a change of reason), and
# stays silent on unchanged ticks. A transition OUT of the kept-state (regained
# work / re-attach / no longer idle / reaped) clears the latch so a later return
# re-logs.
#
# This smoke SOURCES bridge-daemon.sh (the #1679-style non-inheritable in-process
# seam: BASH_SOURCE != $0 ⇒ no verb dispatch), seeds the in-memory roster maps,
# and stubs the tmux / queue / kill helpers so each fixture hits a deterministic
# verdict WITHOUT a live tmux server or SQLite queue. The reaper runs IN THIS
# SHELL (stdout redirected to a file, NOT command substitution) so the on-disk
# latch writes survive across the simulated ticks.
#
# Coverage:
#   T1: first tick over two kept-idle agents (one non-ephemeral, one loop=1)
#       -> BOTH keep lines emitted (no prior latch == a transition).
#   T2: identical tick, nothing changed
#       -> NEITHER keep line emitted (latched-silent: the core NB-1 fix).
#   T3: the non-ephemeral agent regains queue work (no longer a keep candidate),
#       then on the NEXT tick goes idle-and-empty again
#       -> the keep line re-emits (kept -> active -> kept is a fresh transition).
#   T4: the reap path clears the latch (an ephemeral worker is reaped) so a
#       re-used id does not carry a stale token.
#   Wiring guard: the reaper source still routes both keep lines through the
#       latch helper, and the disable knob (threshold=0) is intact.
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at a python3
# subprocess in this smoke.

set -euo pipefail

SMOKE_NAME="1797-reaper-keep-audit-latch"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# Small threshold so the fixtures' canned idle values are unambiguous.
export BRIDGE_DYNAMIC_IDLE_REAP_SECONDS=100

# Source the daemon's functions into THIS shell (verb dispatch gated on
# BASH_SOURCE == $0, false here).
# shellcheck source=bridge-daemon.sh
source "$SMOKE_REPO_ROOT/bridge-daemon.sh"

# --- Deterministic stubs for the reaper's external dependencies -------------
declare -A SESSION_ATTACHED=()
declare -A SESSION_IDLE=()
declare -A SESSION_QUEUE_NONEMPTY=()

KILLED_FILE="$SMOKE_TMP_ROOT/killed.txt"
: >"$KILLED_FILE"

bridge_tmux_session_exists() { return 0; }

bridge_tmux_session_attached_count() {
  local session="$1"
  printf '%s' "${SESSION_ATTACHED[$session]-0}"
}

bridge_tmux_session_idle_seconds() {
  local session="$1"
  printf '%s' "${SESSION_IDLE[$session]-0}"
}

bridge_queue_cli() {
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

bridge_kill_agent_session() {
  local agent="$1"
  printf '%s\n' "$agent" >>"$KILLED_FILE"
  return 0
}
bridge_archive_dynamic_agent() { return 0; }
bridge_remove_dynamic_agent_file() { return 0; }

# --- Roster fixtures --------------------------------------------------------
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

# op-pair: ephemeral=0, loop=0, idle past threshold -> KEPT (non-ephemeral)
register_dynamic op-pair 0 0 0 "$IDLE_PAST" 0
# loop-worker: ephemeral=1, loop=1, idle past threshold -> KEPT (loop)
register_dynamic loop-worker 1 1 0 "$IDLE_PAST" 0

# Run one reaper tick into a fresh log file, echo its path.
run_tick() {
  local log="$1"
  reap_idle_dynamic_agents >"$log" 2>&1 || true
}

# --- T1: first tick over two never-before-seen kept-idle agents -------------
T1="$SMOKE_TMP_ROOT/t1.log"
run_tick "$T1"
T1_OUT="$(cat "$T1")"
smoke_log "T1 (first tick) output:"
sed 's/^/    /' "$T1"

smoke_assert_contains "$T1_OUT" "reaper kept idle dynamic op-pair" \
  "T1: first kept transition for the non-ephemeral agent logs"
smoke_assert_contains "$T1_OUT" "reaper kept idle dynamic loop-worker" \
  "T1: first kept transition for the loop agent logs"

# The latch files must now exist with the expected reason tokens.
LATCH_DIR="$BRIDGE_STATE_DIR/reaper-keep-audit"
smoke_assert_eq "non-ephemeral" "$(cat "$LATCH_DIR/op-pair" 2>/dev/null || true)" \
  "T1: op-pair latched on the non-ephemeral reason token"
smoke_assert_eq "loop" "$(cat "$LATCH_DIR/loop-worker" 2>/dev/null || true)" \
  "T1: loop-worker latched on the loop reason token"

# --- T2: identical tick, nothing changed -> SILENT (the core NB-1 fix) ------
T2="$SMOKE_TMP_ROOT/t2.log"
run_tick "$T2"
T2_OUT="$(cat "$T2")"
smoke_log "T2 (unchanged tick) output:"
sed 's/^/    /' "$T2"

smoke_assert_not_contains "$T2_OUT" "reaper kept idle dynamic op-pair" \
  "T2: unchanged non-ephemeral keep is latched-silent (no per-tick spam)"
smoke_assert_not_contains "$T2_OUT" "reaper kept idle dynamic loop-worker" \
  "T2: unchanged loop keep is latched-silent (no per-tick spam)"

# --- T3: kept -> active -> kept is a fresh transition -----------------------
# op-pair regains queue work this tick (clears the latch, no keep line), then
# goes idle-and-empty again on the next tick (re-logs the keep transition).
SESSION_QUEUE_NONEMPTY["op-pair"]=1
T3A="$SMOKE_TMP_ROOT/t3a.log"
run_tick "$T3A"
T3A_OUT="$(cat "$T3A")"
smoke_assert_not_contains "$T3A_OUT" "reaper kept idle dynamic op-pair" \
  "T3a: an agent that regained work is no longer kept-logged"
[[ -e "$LATCH_DIR/op-pair" ]] \
  && smoke_fail "T3a: latch for op-pair must be cleared once it regains work"

SESSION_QUEUE_NONEMPTY["op-pair"]=0
T3B="$SMOKE_TMP_ROOT/t3b.log"
run_tick "$T3B"
T3B_OUT="$(cat "$T3B")"
smoke_assert_contains "$T3B_OUT" "reaper kept idle dynamic op-pair" \
  "T3b: returning to the idle-kept state re-logs the transition"

# --- T4: reaping an ephemeral worker clears its latch -----------------------
# Register an ephemeral non-loop worker. To make this a genuine regression guard
# (not a vacuous "absent stays absent" check), SEED a stale keep-latch for it
# first — e.g. as if it had been kept on a prior tick before its disposability
# changed — then assert the reap path removes it. If the reap branch ever stops
# calling bridge_reaper_keep_audit_clear, this assertion fails.
register_dynamic wave-fixer 1 0 0 "$IDLE_PAST" 0
mkdir -p "$LATCH_DIR"
printf 'non-ephemeral\n' >"$LATCH_DIR/wave-fixer"
[[ -e "$LATCH_DIR/wave-fixer" ]] \
  || smoke_fail "T4: failed to seed the stale latch fixture"
T4="$SMOKE_TMP_ROOT/t4.log"
run_tick "$T4"
T4_OUT="$(cat "$T4")"
smoke_log "T4 (reap) output:"
sed 's/^/    /' "$T4"

grep -qxF wave-fixer "$KILLED_FILE" \
  || smoke_fail "T4: ephemeral non-loop worker was not reaped"
smoke_assert_contains "$T4_OUT" "reaped dynamic wave-fixer" \
  "T4: reap audit emitted for the ephemeral worker"
[[ -e "$LATCH_DIR/wave-fixer" ]] \
  && smoke_fail "T4: reaped agent must clear its (seeded) keep-latch file"
# The two kept agents stay latched-silent on this tick.
smoke_assert_not_contains "$T4_OUT" "reaper kept idle dynamic loop-worker" \
  "T4: loop keep stays latched-silent while an unrelated agent is reaped"

# --- Disable knob: threshold=0 short-circuits the whole reaper --------------
: >"$KILLED_FILE"
BRIDGE_DYNAMIC_IDLE_REAP_SECONDS=0 reap_idle_dynamic_agents >/dev/null 2>&1 || true
killed_total="$(grep -c . "$KILLED_FILE" 2>/dev/null)" || killed_total=0
smoke_assert_eq "0" "$killed_total" \
  "BRIDGE_DYNAMIC_IDLE_REAP_SECONDS=0 must disable the reaper entirely"

# --- In-source wiring guard -------------------------------------------------
# The keep-audit lines must route through the transition latch; a refactor that
# reverts to a bare daemon_info per tick re-opens the #1797 log-volume footgun.
DAEMON_SRC="$SMOKE_REPO_ROOT/bridge-daemon.sh"
grep -q 'bridge_reaper_keep_audit_latch "\$agent" "loop"' "$DAEMON_SRC" \
  || smoke_fail "S1: loop keep-audit no longer routes through the latch"
grep -q 'bridge_reaper_keep_audit_latch "\$agent" "non-ephemeral"' "$DAEMON_SRC" \
  || smoke_fail "S2: non-ephemeral keep-audit no longer routes through the latch"
grep -q 'bridge_reaper_keep_audit_clear "\$agent"' "$DAEMON_SRC" \
  || smoke_fail "S3: reaper no longer clears the keep-latch on transitions out"

smoke_log "PASS"
