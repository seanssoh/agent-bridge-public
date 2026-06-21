#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2043-picker-autoresolve-active-fp.sh — Issue #2043.
#
# The picker auto-resolve unknown_stuck detector escalated a roster-authoritative
# CLAUDE agent (the admin, `patch`) while it was MID-TURN doing active work —
# running tool calls / streaming assistant output. The captured pane was the
# agent's own LIVE working screen, not a stuck interactive prompt, yet it was
# classified `picker_id=unknown reason=unknown_stuck` and a HIGH-priority task was
# filed to the admin inbox. The agent was not stuck; it was actively producing
# output that happened to be momentarily static when the snapshot was taken.
#
# Root cause: bridge_picker_handle_unknown relied solely on the pane-hash dwell
# (2-tick budget + N-minute wall clock) to decide "stuck". The top-of-tick busy
# skip (bridge_tmux_session_inject_busy → bridge_tmux_claude_capture_is_midturn,
# the #1409 active-work signal) covers most ticks, but a momentarily-static
# capture can slip past it and, if the pane hashes stably across the budget,
# escalate an actively-working roster-claude turn.
#
# The fix re-asserts the SAME #1409/#1991-family active-work signal on the exact
# snapshot about to be escalated: a claude pane whose LIVE tail shows the
# "Working" / "esc to interrupt" spinner banner is mid-turn (active), not stuck —
# bridge_picker_handle_unknown excludes it and resets the dwell timer. A
# genuinely-stuck UNKNOWN picker (a static interactive prompt with NO live
# banner) is NOT excluded and STILL escalates — the real detector is preserved.
#
# Both directions are asserted end-to-end through the shell resolver stage:
#   FP   — an active claude assistant turn (Working banner as live tail), held
#          unchanged across many ticks, NEVER escalates as unknown_stuck.
#   REAL — a genuinely-stuck unknown picker (static, no banner, no catalog match),
#          held unchanged past the 2-tick budget, DOES escalate exactly once.
#   MUTATION — the active fixture is BOTH prompt-like AND mid-turn, so WITHOUT the
#          active exclusion it would walk the unknown path and escalate; the
#          discriminator is the only thing suppressing it (revert it → the active
#          turn falsely escalates, which the FP assertion then catches).
#
# tmux + queue are mocked exactly like 1762-picker-autoresolve.sh /
# 1783-picker-idle-nonpicker.sh: fixture pane text + a bridge-task.sh recorder
# stub. Footgun #11: the py helper is invoked file-as-argv; fixtures are written
# with printf to tempfiles.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (matches sibling smokes).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:2043-picker-autoresolve-active-fp] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="2043-picker-autoresolve-active-fp"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "2043-picker-autoresolve-active-fp"

REPO_ROOT="$SMOKE_REPO_ROOT"
PICKER_SH="$REPO_ROOT/lib/bridge-picker.sh"
PICKER_PY="$REPO_ROOT/lib/bridge-picker.py"

smoke_assert_file_exists "$PICKER_SH" "lib/bridge-picker.sh present"
smoke_assert_file_exists "$PICKER_PY" "lib/bridge-picker.py present"
smoke_require_cmd python3

export BRIDGE_SCRIPT_DIR="$REPO_ROOT"

# Source bridge-lib.sh at the TOP (a mid-run source could trigger the Bash 3.2->4
# re-exec and restart the whole smoke).
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"
declare -F bridge_picker_resolve_session >/dev/null \
  || smoke_fail "bridge_picker_resolve_session not defined after sourcing bridge-lib.sh"
declare -F bridge_picker_handle_unknown >/dev/null \
  || smoke_fail "bridge_picker_handle_unknown not defined"
declare -F bridge_picker_pane_looks_prompt_like >/dev/null \
  || smoke_fail "bridge_picker_pane_looks_prompt_like not defined"
declare -F bridge_tmux_claude_capture_is_midturn >/dev/null \
  || smoke_fail "bridge_tmux_claude_capture_is_midturn not defined (the #1409/#2043 active-work signal)"

# ---------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------
# ACTIVE claude assistant turn: the LIVE tail is the spinner banner
# ("✻ Working… (esc to interrupt)") with NO clean composer prompt below it. This
# is the #2043 capture — a roster-claude agent mid-turn whose screen happened to
# be momentarily static. It is deliberately ALSO prompt-like (a '❯ '-led option-
# shaped line of streamed output) so that, WITHOUT the active exclusion, it would
# walk the unknown path and falsely escalate.
CLAUDE_ACTIVE_TURN=$'⏺ Editing lib/bridge-picker.sh\n❯ 1. apply the focused edit and re-run bash -n\n  reviewing the change before the next tool call\n\n✻ Working… (esc to interrupt)\n'
# GENUINELY-STUCK unknown picker: a static interactive prompt that matches NO
# catalog entry and has NO live spinner banner. This is the case the detector
# legitimately exists for — it must STILL escalate.
STUCK_UNKNOWN_PICKER=$'A newer toolchain is available. Install it now?\n❯ 1. Yes, install and restart\n  2. No, keep the current version\n'

# ---------------------------------------------------------------------
# Unit-level discriminator (pins the mutation at the helper boundary).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_discriminator_unit() {
  smoke_log "unit: active-turn → mid-turn TRUE; stuck-picker → mid-turn FALSE"
  bridge_tmux_claude_capture_is_midturn "$CLAUDE_ACTIVE_TURN" \
    || smoke_fail "unit: active claude turn (live Working banner) must read as mid-turn"
  bridge_tmux_claude_capture_is_midturn "$STUCK_UNKNOWN_PICKER" \
    && smoke_fail "unit: a genuinely-stuck unknown picker must NOT read as mid-turn (would suppress real escalation)"

  # MUTATION anchor: the active fixture is ALSO prompt-like, so the ONLY thing
  # keeping it out of the unknown-stuck path is the active exclusion. If the
  # exclusion were removed, the FP assertion below would escalate it.
  bridge_picker_pane_looks_prompt_like "$CLAUDE_ACTIVE_TURN" \
    || smoke_fail "unit: the active-turn fixture must be prompt-like, else the FP test is vacuous"
  # And the stuck fixture is prompt-like too (it is a real prompt) — so the REAL
  # test is exercising the budget path, not a non-prompt-like early-out.
  bridge_picker_pane_looks_prompt_like "$STUCK_UNKNOWN_PICKER" \
    || smoke_fail "unit: the stuck-picker fixture must be prompt-like, else the escalate test is vacuous"
}

# ---------------------------------------------------------------------
# Shell-stage harness: mock the tmux + queue primitives so the resolver runs
# against fixture panes. Modeled on 1783-picker-idle-nonpicker.sh.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
setup_shell_stage() {
  export BRIDGE_PICKER_AUTORESOLVE=1
  export BRIDGE_PICKER_LOCAL_CATALOG="/nonexistent-local-catalog.json"
  export BRIDGE_PICKER_SETTLE_SECONDS=0
  export BRIDGE_ADMIN_AGENT_ID="admin"
  export BRIDGE_PICKER_STATE_DIR="$SMOKE_TMP_ROOT/pstate"

  # tmux read primitive → the current fixture pane.
  SMOKE_PANE=""
  # shellcheck disable=SC2329
  bridge_capture_recent() {
    printf '%s\n' "$SMOKE_PANE"
  }
  # shellcheck disable=SC2329
  bridge_tmux_session_exists() { return 0; }
  # The top-of-tick cheap busy-skip is deliberately stubbed OFF so the resolver
  # reaches the unknown path. This proves the #2043 fix is the LAST-MILE guard
  # inside bridge_picker_handle_unknown, not merely the pre-existing busy-skip:
  # the exact gap the bug slipped through (a snapshot that read non-busy at
  # busy-check time but is still an active turn when about to escalate).
  # shellcheck disable=SC2329
  bridge_tmux_session_inject_busy() { return 1; }
  # shellcheck disable=SC2329
  bridge_tmux_prepare_claude_session() { return 0; }
  # shellcheck disable=SC2329
  bridge_tmux_send_picker_key() {
    SMOKE_KEYS="${SMOKE_KEYS:-}${SMOKE_KEYS:+ }$4"
    return 0
  }

  # Record escalations instead of filing real queue tasks.
  SMOKE_ESCALATIONS="$SMOKE_TMP_ROOT/escalations.log"
  : >"$SMOKE_ESCALATIONS"
  export SMOKE_ESCALATIONS
  local fake_task="$SMOKE_TMP_ROOT/bridge-task-recorder.sh"
  cat >"$fake_task" <<'TASKEOF'
#!/usr/bin/env bash
printf 'escalation\n' >>"$SMOKE_ESCALATIONS"
exit 0
TASKEOF
  chmod +x "$fake_task"
  export BRIDGE_PICKER_TASK_SCRIPT="$fake_task"
}

# shellcheck disable=SC2329
count_escalations() {
  local n=0 line
  if [[ -f "${SMOKE_ESCALATIONS:-}" ]]; then
    while IFS= read -r line; do
      [[ "$line" == escalation ]] && n=$((n + 1))
    done <"$SMOKE_ESCALATIONS"
  fi
  printf '%s' "$n"
}

# Drive one resolve tick for a single session against a fixed fixture pane.
# shellcheck disable=SC2329
resolve_tick() {
  local agent="$1" session="$2" engine="$3" pane="$4"
  SMOKE_PANE="$pane"
  bridge_picker_resolve_session "$agent" "$session" "$engine" || true
}

# ---------------------------------------------------------------------
# FP — an ACTIVE roster-claude turn NEVER escalates as unknown_stuck.
# unknown_stuck_minutes=0 so the only gate is the 2-tick budget; WITHOUT the
# active exclusion this fixture (prompt-like + stable hash) would escalate on the
# 2nd tick. This is the #2043 regression assertion.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_fp_active_turn_never_escalates() {
  smoke_log "FP: active claude assistant turn over many ticks → ZERO unknown_stuck escalations"
  local zerobudget="$SMOKE_TMP_ROOT/zerobudget.json"
  printf '%s' '{"version":1,"defaults":{"unknown_stuck_minutes":0}}' >"$zerobudget"
  export BRIDGE_PICKER_LOCAL_CATALOG="$zerobudget"

  python3 "$PICKER_PY" clear-unknown --session sActiveC --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  local before; before="$(count_escalations)"
  local i
  for i in 1 2 3 4; do
    SMOKE_KEYS=""
    resolve_tick "patch" "sActiveC" "claude" "$CLAUDE_ACTIVE_TURN"
    smoke_assert_eq "" "${SMOKE_KEYS:-}" "FP: active turn sends ZERO keystrokes (tick $i)"
  done
  smoke_assert_eq "$before" "$(count_escalations)" "FP: an actively-working roster-claude turn NEVER escalates as unknown_stuck (#2043)"

  export BRIDGE_PICKER_LOCAL_CATALOG="/nonexistent-local-catalog.json"
}

# ---------------------------------------------------------------------
# REAL — a genuinely-stuck UNKNOWN picker DOES still escalate exactly once. This
# proves the active exclusion did not neuter the detector the brief mandates we
# preserve: stable, non-advancing, no live banner, no catalog match → escalate.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_real_stuck_picker_still_escalates() {
  smoke_log "REAL: a genuinely-stuck unknown picker still escalates exactly once"
  local zerobudget="$SMOKE_TMP_ROOT/zerobudget.json"
  printf '%s' '{"version":1,"defaults":{"unknown_stuck_minutes":0}}' >"$zerobudget"
  export BRIDGE_PICKER_LOCAL_CATALOG="$zerobudget"

  # Fresh per-pass storm-fuse counter (this smoke drives resolve_session directly,
  # not scan_all_sessions which resets it per pass).
  BRIDGE_PICKER_UNKNOWN_PASS_COUNT=0
  python3 "$PICKER_PY" clear-unknown --session sStuckC --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true

  local b; b="$(count_escalations)"
  # Tick 1 arms the 2-tick budget; no escalation yet.
  resolve_tick "patch" "sStuckC" "claude" "$STUCK_UNKNOWN_PICKER"
  smoke_assert_eq "$b" "$(count_escalations)" "REAL: stuck unknown picker tick 1 arms the budget (no escalation yet)"
  # Tick 2: same hash past the (zeroed) minute budget → escalate exactly once.
  resolve_tick "patch" "sStuckC" "claude" "$STUCK_UNKNOWN_PICKER"
  (( $(count_escalations) == b + 1 )) \
    || smoke_fail "REAL: a genuinely-stuck unknown picker must escalate exactly once (before=$b after=$(count_escalations)) — the active exclusion must NOT neuter real detection"

  export BRIDGE_PICKER_LOCAL_CATALOG="/nonexistent-local-catalog.json"
}

smoke_run "unit: active-vs-stuck discriminator" test_discriminator_unit

setup_shell_stage

smoke_run "FP: active claude turn never escalates" test_fp_active_turn_never_escalates
smoke_run "REAL: stuck unknown picker still escalates" test_real_stuck_picker_still_escalates

smoke_log "all #2043 active-turn false-positive + real-stuck-picker checks pass"
exit 0
