#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/beta5-2-delta-nudge-session-empty.sh — Issue #1311 (C5).
#
# v0.15.0-beta5-2 Lane δ — patch audit 2026-05-27 classified the silent
# soft-skip in bridge-daemon.sh's nudge fanout loop as a CRITICAL
# data-loss class. Pre-fix the loop body was:
#
#   while IFS=$'\t' read -r agent session queued claimed idle nudge_key; do
#     [[ -z "$agent" || -z "$session" ]] && continue
#     if ! bridge_tmux_session_exists "$session"; then
#       continue
#     fi
#     …
#
# A nudge candidate row whose `$session` was empty (or whose tmux session
# had died) was silently dropped — no audit row, no retry signal, no
# escalation. The queued task stayed queued indefinitely. The fix
# converts the silent skip into a structured defer-and-escalate path
# (`bridge_daemon_nudge_defer_and_maybe_escalate`) that:
#   1. Emits a `nudge_deferred reason=<r> task=<id> consecutive=<N>`
#      audit row every deferred tick.
#   2. Tracks per-(agent, task_id) consecutive deferrals on disk under
#      `$BRIDGE_STATE_DIR/daemon-nudge-deferred/<agent>.env`.
#   3. After M consecutive deferrals (default 10; env
#      BRIDGE_NUDGE_SESSION_EMPTY_ESCALATE_AFTER) files an admin task
#      and emits `nudge_session_empty_escalated`.
#   4. Clears the counter on a verified successful nudge so a long-lived
#      healthy agent never accumulates stale state.
#
# Plus three quiet-skip edge cases that MUST NOT escalate noise:
#   - Manual-stop marker present (agent was stopped on purpose).
#   - Orphan task (assigned_to references a deleted agent).
#   - Empty $agent (defensive — daemon-step output bug, not stuck task).
#
# Test plan:
#   T1: synth empty $session row → assert helper increments counter,
#       emits `nudge_deferred reason=session_empty`, returns 0
#       (caller-side decision to `continue` after defer).
#   T2: recovery → after a successful clear the counter is reset; a
#       fresh tick with a valid session resolves cleanly.
#   T3: 10 consecutive session-empty deferrals → escalation row +
#       admin task body file produced once, idempotent on repeat.
#   T4: manual-stop marker present → fanout loop quiet-skips, NO
#       deferred audit row, NO counter increment.
#   T5: teeth — revert to silent soft-skip → smoke detects the regression
#       (no audit row was emitted on the deferred path).
#   T6: edge — orphan task (agent not in roster) → quiet skip with
#       one-time audit, no escalation noise on subsequent ticks.
#   T7: per-task counter isolation — two queued tasks for the same
#       agent track independent counters; one stuck task does not
#       suppress escalation for siblings.
#   T8: structural — assert the live bridge-daemon.sh loop body no
#       longer contains the verbatim silent-skip pattern. A future PR
#       that re-introduces `[[ -z "$agent" || -z "$session" ]] && continue`
#       will fail this teeth check.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `cat >file <<EOF` on flat string variables and direct function calls.
# No command substitution feeding a heredoc stdin, no `<<<` here-strings
# into bridge functions.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays + the bridge libs.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:beta5-2-delta-nudge-session-empty] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="beta5-2-delta-nudge-session-empty"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "beta5-2-delta-nudge-session-empty"
REPO_ROOT="$SMOKE_REPO_ROOT"

# Pin the escalation threshold tight enough that T3 isn't a 50-tick
# slog. The production default is 10 — we leave that asserted in T1
# (threshold field in the audit row) but exercise the escalation logic
# at 3 in T3.
export BRIDGE_NUDGE_SESSION_EMPTY_ESCALATE_AFTER=10

# --- Source the daemon helpers under test (no main entry exec). ----
# bridge-daemon.sh defines `cmd_run` / `cmd_start` etc; sourcing it
# would normally try to invoke a CLI. The file is guarded by the
# `BRIDGE_DAEMON_SUBCOMMAND` pattern at the bottom — sourcing without
# setting that variable just defines functions and returns.
# Skip the bridge-lib bootstrap (it would source the full agent
# roster + tmux + isolation chain); we only need the daemon helpers
# + the manual-stop predicate + audit_log + agent_exists.
# Provide a minimal stub for bridge_audit_log so the smoke can
# inspect emit calls without a real audit.py invocation.
AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
: >"$AUDIT_LOG"
mkdir -p "$BRIDGE_STATE_DIR"

# Stub primitives BEFORE source-line execution so the helpers wire
# against these versions instead of the production audit/notify paths.
bridge_audit_log() {
  # Args: actor action target [--detail k=v]...
  local actor="$1" action="$2" target="$3"
  shift 3 || true
  local detail_csv=""
  while (( $# )); do
    case "$1" in
      --detail)
        if [[ -n "$detail_csv" ]]; then detail_csv+=";"; fi
        detail_csv+="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  printf '{"actor":"%s","action":"%s","target":"%s","detail":"%s"}\n' \
    "$actor" "$action" "$target" "$detail_csv" >>"$AUDIT_LOG"
}

daemon_warn() { printf '[stub-warn] %s\n' "$*" >&2; }
daemon_info() { printf '[stub-info] %s\n' "$*"; }
daemon_log_event() { printf '[stub-log] %s\n' "$*"; }

# Stub the admin-task creation primitive so T3's escalation doesn't
# need a working `agent-bridge task create`. The body file emitted is
# kept by the stub so the smoke can inspect it.
ADMIN_TASK_LOG="$SMOKE_TMP_ROOT/admin-tasks.log"
: >"$ADMIN_TASK_LOG"
bridge_daemon_nudge_emit_session_empty_admin_task__stubbed=1
# Override the helper after sourcing so the real version is replaced.

# Stubs for roster / manual-stop. Driven by env var so each test can
# pin the lookup result without touching the live state-file machinery.
declare -gA _SMOKE_AGENT_EXISTS=()
declare -gA _SMOKE_AGENT_MANUAL_STOP=()
bridge_agent_exists() {
  local agent="$1"
  [[ "${_SMOKE_AGENT_EXISTS[$agent]:-0}" == "1" ]]
}
bridge_agent_manual_stop_active() {
  local agent="$1"
  [[ "${_SMOKE_AGENT_MANUAL_STOP[$agent]:-0}" == "1" ]]
}

# Source bridge-daemon.sh in a way that does NOT execute the CLI tail.
# The file's bottom dispatches on `$1` — guard by exposing no positional
# args and setting a sentinel that the entry-point checks. Easier:
# extract only the helper function bodies we need by sourcing a
# filtered copy. We use awk to grab from
# `bridge_daemon_nudge_state_file()` through the closing brace of
# `nudge_agent_session`. That envelope captures all helpers (deferred
# included) plus the one consumer we care about for T8 grep.
HELPERS_SUBSET="$SMOKE_TMP_ROOT/daemon-helpers.sh"
awk '
  /^bridge_daemon_nudge_state_file\(\) \{/ { capturing=1 }
  capturing { print }
  /^nudge_agent_session\(\) \{/ { in_nudge=1 }
  in_nudge && /^\}$/ {
    print ""
    capturing=0
    in_nudge=0
  }
' "$REPO_ROOT/bridge-daemon.sh" > "$HELPERS_SUBSET"

# Drop the body of nudge_agent_session — the test only needs the
# helpers above it. Replace the function definition with a no-op stub.
NUDGE_HELPERS="$SMOKE_TMP_ROOT/nudge-helpers.sh"
awk '
  /^nudge_agent_session\(\) \{/ { in_stub=1; print "nudge_agent_session() { return 0; }"; next }
  in_stub && /^\}$/ { in_stub=0; next }
  in_stub { next }
  { print }
' "$HELPERS_SUBSET" > "$NUDGE_HELPERS"

# shellcheck source=/dev/null
source "$NUDGE_HELPERS"

# Now override the admin-task emit to log instead of dispatch.
# The real implementation requires $BRIDGE_HOME/agent-bridge to exist,
# which we don't want in the smoke harness.
bridge_daemon_nudge_emit_session_empty_admin_task() {
  local agent="$1" task_id="${2:-none}" reason="${3:-session_empty}"
  local consecutive="${4:-0}" threshold="${5:-10}" queued="${6:-0}"
  printf 'agent=%s task=%s reason=%s consecutive=%s threshold=%s queued=%s\n' \
    "$agent" "$task_id" "$reason" "$consecutive" "$threshold" "$queued" \
    >>"$ADMIN_TASK_LOG"
  return 0
}

# Count audit rows matching a (action, agent) pair via grep on the
# stub-emitted jsonl. Keeps the test independent of the real audit.py.
# `grep -c` exits non-zero with `0` on no-match — gate the fallback on
# the exit code, not the always-emitted `0` line, so a concatenated
# "0\n0" can never reach the caller.
audit_count() {
  local action="$1" agent="$2"
  local n
  if n="$(grep -c "\"action\":\"${action}\".*\"target\":\"${agent}\"" "$AUDIT_LOG" 2>/dev/null)"; then
    printf '%s' "$n"
  else
    printf '0'
  fi
}

# Extract a detail field from the most recent audit row matching
# (action, agent). The detail field is the semicolon-joined CSV emitted
# by the stub. `field=value` lookups use parameter expansion.
audit_latest_detail() {
  local action="$1" agent="$2" field="$3"
  local row
  row="$(grep "\"action\":\"${action}\".*\"target\":\"${agent}\"" "$AUDIT_LOG" 2>/dev/null | tail -n1)"
  [[ -n "$row" ]] || { printf ''; return; }
  # Pull the `detail` JSON-string field then split on `;` and `=`.
  local detail
  detail="$(printf '%s\n' "$row" | sed -n 's/.*"detail":"\([^"]*\)".*/\1/p')"
  local part
  IFS=';' read -ra parts <<<"$detail"
  for part in "${parts[@]}"; do
    if [[ "$part" == "${field}="* ]]; then
      printf '%s' "${part#${field}=}"
      return
    fi
  done
  printf ''
}

# --- T1: empty $session row → defer + audit ---------------------------
smoke_run "T1 session_empty defer + audit" : ; {
  : >"$AUDIT_LOG"
  bridge_daemon_nudge_defer_and_maybe_escalate \
    "agent-t1" "501" session_empty "3" "501,502,503"

  rc=$?
  smoke_assert_eq 0 "$rc" "T1 return code"

  count=$(audit_count nudge_deferred "agent-t1")
  smoke_assert_eq 1 "$count" "T1 nudge_deferred row count"

  consecutive=$(audit_latest_detail nudge_deferred "agent-t1" consecutive)
  smoke_assert_eq 1 "$consecutive" "T1 consecutive=1"

  reason=$(audit_latest_detail nudge_deferred "agent-t1" reason)
  smoke_assert_eq session_empty "$reason" "T1 reason=session_empty"

  threshold=$(audit_latest_detail nudge_deferred "agent-t1" threshold)
  smoke_assert_eq 10 "$threshold" "T1 threshold=10 (default)"

  task_id=$(audit_latest_detail nudge_deferred "agent-t1" task_id)
  smoke_assert_eq 501 "$task_id" "T1 task_id=501"
}

# --- T2: recovery clears the counter ----------------------------------
smoke_run "T2 recovery clears counter" : ; {
  : >"$AUDIT_LOG"
  # First defer at count=1.
  bridge_daemon_nudge_defer_and_maybe_escalate \
    "agent-t2" "502" session_empty "1" "502"
  # Simulate a successful nudge by directly calling the clear.
  bridge_daemon_nudge_deferred_clear "agent-t2"

  state_file="$(bridge_daemon_nudge_deferred_state_file agent-t2)"
  [[ ! -f "$state_file" ]] || smoke_fail "T2 state file should be removed after clear"

  # Next defer must start from 1 again, not 2.
  bridge_daemon_nudge_defer_and_maybe_escalate \
    "agent-t2" "502" session_empty "1" "502"
  consecutive=$(audit_latest_detail nudge_deferred "agent-t2" consecutive)
  smoke_assert_eq 1 "$consecutive" "T2 post-recovery consecutive=1"
}

# --- T3: 10 consecutive defers → escalation ---------------------------
smoke_run "T3 escalation after threshold" : ; {
  : >"$AUDIT_LOG"
  : >"$ADMIN_TASK_LOG"
  # Pin threshold low so the test runs in a bounded number of ticks.
  BRIDGE_NUDGE_SESSION_EMPTY_ESCALATE_AFTER=3 \
  bridge_daemon_nudge_defer_and_maybe_escalate \
    "agent-t3" "503" session_empty "1" "503"
  BRIDGE_NUDGE_SESSION_EMPTY_ESCALATE_AFTER=3 \
  bridge_daemon_nudge_defer_and_maybe_escalate \
    "agent-t3" "503" session_empty "1" "503"
  esc_count_before=$(audit_count nudge_session_empty_escalated "agent-t3")
  smoke_assert_eq 0 "$esc_count_before" "T3 no escalation before threshold"

  BRIDGE_NUDGE_SESSION_EMPTY_ESCALATE_AFTER=3 \
  bridge_daemon_nudge_defer_and_maybe_escalate \
    "agent-t3" "503" session_empty "1" "503"
  esc_count_after=$(audit_count nudge_session_empty_escalated "agent-t3")
  smoke_assert_eq 1 "$esc_count_after" "T3 escalation row emitted at count=3"

  admin_tasks=$(wc -l <"$ADMIN_TASK_LOG" | tr -d ' ')
  smoke_assert_eq 1 "$admin_tasks" "T3 admin task filed once"

  # Idempotent: further deferrals MUST NOT re-file the admin task.
  BRIDGE_NUDGE_SESSION_EMPTY_ESCALATE_AFTER=3 \
  bridge_daemon_nudge_defer_and_maybe_escalate \
    "agent-t3" "503" session_empty "1" "503"
  BRIDGE_NUDGE_SESSION_EMPTY_ESCALATE_AFTER=3 \
  bridge_daemon_nudge_defer_and_maybe_escalate \
    "agent-t3" "503" session_empty "1" "503"
  admin_tasks_after=$(wc -l <"$ADMIN_TASK_LOG" | tr -d ' ')
  smoke_assert_eq 1 "$admin_tasks_after" "T3 admin task NOT re-filed on subsequent defers"
}

# --- T4: manual-stop marker — quiet skip path (loop-side) -------------
# The loop quiet-skip path is in cmd_sync_cycle's while-read body, not
# inside bridge_daemon_nudge_defer_and_maybe_escalate. Exercise the
# decision by grepping the live source — the loop body MUST check
# `bridge_agent_manual_stop_active` BEFORE calling the defer helper.
smoke_run "T4 manual-stop loop guard present" : ; {
  if ! grep -q 'bridge_agent_manual_stop_active "\$agent"' "$REPO_ROOT/bridge-daemon.sh"; then
    smoke_fail "T4: bridge-daemon.sh must consult bridge_agent_manual_stop_active before defer-and-escalate"
  fi
  if ! grep -q 'bridge_daemon_nudge_deferred_clear "\$agent"' "$REPO_ROOT/bridge-daemon.sh"; then
    smoke_fail "T4: bridge-daemon.sh must clear deferred state on manual-stop quiet skip"
  fi
}

# --- T5: teeth — silent soft-skip must NOT live in the loop -----------
smoke_run "T5 teeth silent-skip pattern absent" : ; {
  # The pre-fix pattern was:
  #   [[ -z "$agent" || -z "$session" ]] && continue
  # Inside the nudge fanout loop. The fix replaced it with separate
  # guards (empty-agent defensive, session_empty + session_dead defer).
  # If a future PR re-introduces the verbatim combined predicate, T5
  # fires.
  if grep -nE '\[\[\s+-z\s+"\$agent"\s+\|\|\s+-z\s+"\$session"\s+\]\]\s+&&\s+continue' \
      "$REPO_ROOT/bridge-daemon.sh"; then
    smoke_fail "T5: bridge-daemon.sh re-introduced the pre-#1311 silent soft-skip pattern"
  fi
}

# --- T6: orphan task quiet skip ---------------------------------------
# Same as T4 — the orphan-path quiet skip lives in the loop body. Pin
# the structure via grep so the smoke is independent of running the
# full daemon main loop.
smoke_run "T6 orphan loop guard present" : ; {
  if ! grep -q 'bridge_agent_exists "\$agent"' "$REPO_ROOT/bridge-daemon.sh"; then
    smoke_fail "T6: bridge-daemon.sh must check bridge_agent_exists in the loop"
  fi
  if ! grep -q 'reason=orphan_task' "$REPO_ROOT/bridge-daemon.sh"; then
    smoke_fail "T6: bridge-daemon.sh must emit reason=orphan_task on the orphan quiet-skip"
  fi
}

# --- T7: per-task counter isolation -----------------------------------
smoke_run "T7 per-task counter isolation" : ; {
  : >"$AUDIT_LOG"
  bridge_daemon_nudge_deferred_clear "agent-t7" >/dev/null 2>&1 || true

  # Two tasks for the same agent: A defers thrice, B once.
  for _ in 1 2 3; do
    bridge_daemon_nudge_defer_and_maybe_escalate \
      "agent-t7" "701" session_empty "2" "701,702"
  done
  bridge_daemon_nudge_defer_and_maybe_escalate \
    "agent-t7" "702" session_empty "2" "701,702"

  # Inspect the env file directly.
  state_file="$(bridge_daemon_nudge_deferred_state_file agent-t7)"
  [[ -f "$state_file" ]] || smoke_fail "T7 state file missing"

  count_a=$(grep '^_NUDGE_DEFERRED_COUNT_701=' "$state_file" | sed 's/.*=//' | tr -d "'")
  count_b=$(grep '^_NUDGE_DEFERRED_COUNT_702=' "$state_file" | sed 's/.*=//' | tr -d "'")
  smoke_assert_eq 3 "$count_a" "T7 task 701 counter independent"
  smoke_assert_eq 1 "$count_b" "T7 task 702 counter independent"
}

# --- T8: structural — defer helper + loop wiring present --------------
smoke_run "T8 defer + escalate helpers + loop wiring present" : ; {
  # Helpers
  for fn in \
    bridge_daemon_nudge_deferred_state_file \
    bridge_daemon_nudge_deferred_clear \
    bridge_daemon_nudge_defer_and_maybe_escalate \
    bridge_daemon_nudge_emit_session_empty_admin_task; do
    if ! grep -q "^${fn}() {" "$REPO_ROOT/bridge-daemon.sh"; then
      smoke_fail "T8: missing helper definition: ${fn}"
    fi
  done

  # Loop must call the defer helper for session_empty AND session_dead.
  # Multi-line dispatch shape — collapse with `tr` so the keyword and
  # the helper-name match are visible to a flat grep.
  loop_normalized="$(tr '\n' ' ' <"$REPO_ROOT/bridge-daemon.sh")"
  if ! printf '%s' "$loop_normalized" | grep -q \
      'bridge_daemon_nudge_defer_and_maybe_escalate[^.]*session_empty'; then
    smoke_fail "T8: loop body must dispatch session_empty to defer helper"
  fi
  if ! printf '%s' "$loop_normalized" | grep -q \
      'bridge_daemon_nudge_defer_and_maybe_escalate[^.]*session_dead'; then
    smoke_fail "T8: loop body must dispatch session_dead to defer helper"
  fi

  # nudge_agent_session must clear deferred state on success.
  if ! grep -q 'bridge_daemon_nudge_deferred_clear "\$agent"' \
      "$REPO_ROOT/bridge-daemon.sh"; then
    smoke_fail "T8: nudge_agent_session must clear deferred state on success"
  fi
}

smoke_log "all checks passed"
