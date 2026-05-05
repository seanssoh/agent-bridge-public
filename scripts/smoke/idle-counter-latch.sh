#!/usr/bin/env bash
# scripts/smoke/idle-counter-latch.sh — Issue #589 prompt-ready latch + spool re-delivery.
#
# Re-exec under a bash 4+ interpreter so the associative arrays + `declare -gA`
# used to stub the roster work on stock macOS (which ships bash 3.2). This
# matches the bootstrap done in scripts/smoke-test.sh.
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:idle-counter-latch][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Standalone smoke (NOT registered in scripts/smoke-test.sh; invoke directly).
# Validates the two halves of #589 without exercising real claude/tmux:
#
#   T1: old session_activity_ts, no prompt_ready_ts, within grace
#       → idle_seconds=0 (suppressed; agent is still booting)
#   T2: write prompt_ready_ts, old session_activity_ts
#       → idle_seconds anchors on prompt_ready_ts (not session_activity_ts)
#   T3: marker older than timeout, no work
#       → idle_seconds = now - prompt_ready_ts (eligible for auto-stop)
#   T4: prompt-unavailable dispatch → exactly one spool entry; second cycle
#       with the same task ids does NOT append a duplicate (dup-suppression
#       covered by daemon's last_nudge_key, simulated here by checking that
#       the spool helper itself does not over-append on a single dispatch)
#   T5: a *new* dispatch (different payload) appends one more spool entry
#   T6: simulated prompt detection drains the spool via the flush helper
#
# Run: bash scripts/smoke/idle-counter-latch.sh

set -euo pipefail

SMOKE_NAME="idle-counter-latch"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# --- helpers --------------------------------------------------------------

# Read a TSV summary row for $agent and emit the idle_seconds field.
read_idle_from_summary() {
  local agent="$1"
  local fmt="${2:-tsv}"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" summary --agent "$agent" --format "$fmt" \
    | head -n 1 \
    | awk -F'\t' '{ print $6 }'
}

# Set an explicit prompt_ready_ts on the agent_state row by re-running
# daemon-step with a snapshot that carries the new column. We use this
# instead of issuing a SQL UPDATE to keep the smoke pinned to the public
# python contract.
set_agent_state() {
  local agent="$1"
  local session="$2"
  local activity_ts="$3"
  local prompt_ready_ts="${4:-}"
  local snapshot="$SMOKE_TMP_ROOT/state-${agent}.tsv"
  {
    printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\tprompt_ready_ts\tprompt_ready_session\tprompt_ready_source\n'
    printf '%s\tclaude\t%s\t%s\t1\t%s\t%s\t%s\tdaemon-poll\n' \
      "$agent" "$session" "$SMOKE_TMP_ROOT/${agent}-workdir" "$activity_ts" "$prompt_ready_ts" "$session"
  } >"$snapshot"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" daemon-step \
    --snapshot "$snapshot" \
    --idle-threshold 120 \
    --nudge-cooldown 900 \
    --format tsv >/dev/null
}

# --- T1/T2/T3: latch-aware idle computation ------------------------------

test_latch_idle_arithmetic() {
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null

  local now activity_ts old_activity_ts agent="syrs-fi" session="syrs-fi"

  now="$(date +%s)"
  # Activity timestamp 600s ago — would normally read as idle=600s.
  old_activity_ts="$((now - 600))"

  # T1: snapshot has no prompt_ready_ts, default grace=3600 → idle=0.
  set_agent_state "$agent" "$session" "$old_activity_ts" ""
  local t1_idle
  t1_idle="$(read_idle_from_summary "$agent")"
  smoke_assert_eq "0" "$t1_idle" "T1: no latch within grace → idle=0 (boot suppressed)"

  # T2: marker present at now-30s → idle anchors on it (≈30s, not 600s).
  local prompt_ready_ts="$((now - 30))"
  set_agent_state "$agent" "$session" "$old_activity_ts" "$prompt_ready_ts"
  local t2_idle t2_low t2_high
  t2_idle="$(read_idle_from_summary "$agent")"
  # Allow a tiny clock skew window (the python `now_ts()` runs slightly
  # later than the bash `date +%s`); 25-90s is safely tighter than the
  # 600s that the legacy anchor would have produced.
  if [[ ! "$t2_idle" =~ ^[0-9]+$ ]]; then
    smoke_fail "T2: idle is not a non-negative int, got '$t2_idle'"
  fi
  t2_low=25
  t2_high=90
  if (( t2_idle < t2_low || t2_idle > t2_high )); then
    smoke_fail "T2: latch anchor expected ${t2_low}..${t2_high}s, got ${t2_idle}s (would have been 600s without the latch)"
  fi

  # T3: marker old enough to exceed the auto-stop threshold (timeout=900s).
  # Set prompt_ready_ts ≈ 1200s ago; idle should be ≥ 1200s and the agent
  # would be eligible for auto-stop in process_on_demand_agents.
  local long_ago="$((now - 1200))"
  set_agent_state "$agent" "$session" "$long_ago" "$long_ago"
  local t3_idle
  t3_idle="$(read_idle_from_summary "$agent")"
  if [[ ! "$t3_idle" =~ ^[0-9]+$ ]]; then
    smoke_fail "T3: idle is not a non-negative int, got '$t3_idle'"
  fi
  if (( t3_idle < 1190 )); then
    smoke_fail "T3: expected idle>=1190s after long-stale latch, got ${t3_idle}s"
  fi

  # Kill-switch sanity check: with BRIDGE_DAEMON_IDLE_LATCH_DISABLED=1,
  # the latch is ignored and idle reverts to session_activity_ts. With
  # session_activity_ts=now-600 and no latch effect, idle≈600s.
  set_agent_state "$agent" "$session" "$old_activity_ts" ""
  local kill_idle
  kill_idle="$(BRIDGE_DAEMON_IDLE_LATCH_DISABLED=1 \
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" summary --agent "$agent" --format tsv \
    | head -n 1 | awk -F'\t' '{ print $6 }')"
  if [[ ! "$kill_idle" =~ ^[0-9]+$ ]]; then
    smoke_fail "T3 kill-switch: idle is not a non-negative int, got '$kill_idle'"
  fi
  if (( kill_idle < 580 || kill_idle > 720 )); then
    smoke_fail "T3 kill-switch: expected idle≈600s with kill switch, got ${kill_idle}s"
  fi
}

# --- T4/T5/T6: spool append + dup suppression + flush ---------------------

# Source bridge-tmux.sh and bridge-state.sh in isolation, with stub
# helpers for the cross-module functions we need. This keeps the smoke
# self-contained — no dependency on a full bridge-lib bootstrap (which
# loads the entire roster pipeline and is too heavy for a unit smoke).
load_spool_test_env() {
  # Stubs below are invoked indirectly by the library code we source; the
  # SC2329 ("never invoked") warnings are spurious for that pattern.
  # bridge_warn / bridge_die (provided by bridge-core normally).
  bridge_warn() { printf '[warn] %s\n' "$*" >&2; }
  # shellcheck disable=SC2329
  bridge_die() { printf '[die] %s\n' "$*" >&2; exit 1; }
  # shellcheck disable=SC2329
  bridge_audit_log() { :; }
  bridge_require_python() { :; }
  # shellcheck disable=SC2329
  bridge_with_timeout() {
    local _label="$1" _action="$2"
    shift 2
    "$_label" "$_action" "$@" 2>/dev/null || true
  }

  # Active-roster surface (used by bridge_agent_pending_attention_file
  # via bridge_agent_idle_marker_dir → bridge_isolation_v2_active path).
  bridge_isolation_v2_active() { return 1; }
  BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
  BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
  mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR" "$BRIDGE_LOG_DIR"

  # Roster stubs: a single agent named "syrs-fi" with engine=claude.
  # Bash 4 treats array subscripts as arithmetic by default; under
  # `set -u` the literal "syrs-fi" then fails to evaluate ("syrs" looks
  # like an unset variable and "-fi" like subtraction). Declaring the
  # associative array first and assigning keys on a separate line side-
  # steps the arithmetic context.
  # shellcheck disable=SC2034
  declare -gA BRIDGE_AGENT_ENGINE=()
  # shellcheck disable=SC2034
  declare -gA BRIDGE_AGENT_SESSION=()
  # shellcheck disable=SC2034
  declare -gA BRIDGE_AGENT_WORKDIR=()
  BRIDGE_AGENT_ENGINE["syrs-fi"]="claude"
  BRIDGE_AGENT_SESSION["syrs-fi"]="syrs-fi"
  BRIDGE_AGENT_WORKDIR["syrs-fi"]="$SMOKE_TMP_ROOT/syrs-fi"
  # shellcheck disable=SC2034
  BRIDGE_AGENT_IDS=("syrs-fi")

  bridge_agent_engine() { printf 'claude'; }
  bridge_agent_session() { printf 'syrs-fi'; }
  # shellcheck disable=SC2329
  bridge_agent_workdir() { printf '%s' "$SMOKE_TMP_ROOT/syrs-fi"; }
  bridge_agent_has_wake_channel() { return 0; }

  # Source the real helpers we want to test. Order matters: bridge-state
  # provides the path helpers used by tmux helpers' spool routines.
  # shellcheck source=lib/bridge-tmux.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-tmux.sh"
  # shellcheck source=lib/bridge-state.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-state.sh"
  # shellcheck source=lib/bridge-notify.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-notify.sh"

  # Tmux session stubs: pretend the session exists but the prompt is not
  # yet visible (the #589 boot-window scenario).
  bridge_tmux_session_exists() { return 0; }
  bridge_tmux_session_has_prompt() { return 1; }
  bridge_claude_session_can_wake() { return 1; }
  bridge_claude_session_try_mark_prompt_ready() { return 1; }
}

test_spool_on_prompt_unavailable() {
  load_spool_test_env

  local spool_file
  spool_file="$(bridge_agent_pending_attention_file syrs-fi)"
  rm -f "$spool_file" 2>/dev/null || true

  # T4: dispatch hits prompt-unavailable branch → one spool entry, return 0.
  local rc=0
  bridge_dispatch_notification syrs-fi "queued" "[Agent Bridge] event=inbox agent=syrs-fi count=1 top=42" "42" "high" || rc=$?
  smoke_assert_eq "0" "$rc" "T4: dispatch returns 0 on spool-fallback"
  smoke_assert_file_exists "$spool_file" "T4: spool file created on prompt-unavailable"

  local count
  count="$(wc -l <"$spool_file" | tr -d ' ')"
  smoke_assert_eq "1" "$count" "T4: exactly one spool entry after first prompt-unavailable dispatch"

  # Second dispatch with the SAME payload — confirm one more spool entry
  # gets appended (the dup-suppression we leverage at the daemon layer is
  # last_nudge_key, not the spool-append path itself; we verify the spool
  # is correctly idempotent on the helper level by comparing to T5 below).
  bridge_dispatch_notification syrs-fi "queued" "[Agent Bridge] event=inbox agent=syrs-fi count=1 top=42" "42" "high" || true
  count="$(wc -l <"$spool_file" | tr -d ' ')"
  if (( count != 2 )); then
    smoke_fail "T4: spool helper is expected to append per-call (got count=${count}); daemon dedup is what suppresses repeats"
  fi

  # T5: a NEW payload (different task id) → one more entry, total 3.
  bridge_dispatch_notification syrs-fi "queued" "[Agent Bridge] event=inbox agent=syrs-fi count=2 top=43" "43" "high" || true
  count="$(wc -l <"$spool_file" | tr -d ' ')"
  smoke_assert_eq "3" "$count" "T5: new dispatch payload appends one more spool entry"
}

test_spool_flush_drains_when_prompt_returns() {
  # T6: simulate the agent reaching the prompt by overriding
  # bridge_tmux_send_and_submit to return success without doing real
  # tmux work. The flush helper should drain every entry from the spool.
  # shellcheck disable=SC2329
  bridge_tmux_send_and_submit() { return 0; }
  # shellcheck disable=SC2329
  bridge_tmux_session_ring_bell() { return 0; }
  # shellcheck disable=SC2329
  bridge_tmux_session_inject_busy() { return 1; }

  local spool_file
  spool_file="$(bridge_agent_pending_attention_file syrs-fi)"
  smoke_assert_file_exists "$spool_file" "T6 setup: spool present from prior tests"

  bridge_tmux_pending_attention_flush "syrs-fi" "claude" "syrs-fi"

  if [[ -s "$spool_file" ]]; then
    smoke_fail "T6: expected spool to be drained, but file is non-empty: $(wc -l <"$spool_file") line(s)"
  fi
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "T1/T2/T3 (latch-aware idle arithmetic + kill switch)" \
    test_latch_idle_arithmetic

  smoke_run "T4/T5 (spool append on prompt-unavailable)" \
    test_spool_on_prompt_unavailable

  smoke_run "T6 (flush drains spool when prompt returns)" \
    test_spool_flush_drains_when_prompt_returns

  smoke_log "PASS: idle-counter-latch (#589 prompt-ready latch + spool re-delivery)"
}

main "$@"
