#!/usr/bin/env bash
# scripts/smoke/1639-post-restart-auto-wake.sh — regression for issue #1639.
#
# THE BUG (cm-prod iso v2, HIGH). After an upgrade/daemon/watchdog auto-restart
# of an agent, the fresh Claude Code session opens but sits FULLY IDLE: the
# SessionStart hook runs as a shell process, but its result only surfaces as a
# system-reminder on the NEXT user message — so with no user turn, no Claude
# turn ever starts, and pending/blocked queue work stalls until a human types.
#
# THE FIX (two surfaces, both pinned here):
#   1. bridge-start.sh — propagate BRIDGE_AUTO_RESTART_WAKE=1 into the launched
#      bridge-run.sh loop's SESSION_CMD env prefix ONLY on a non-interactive
#      (auto-restart) launch (ATTACH=0 — daemon / upgrade / `bridge-agent.sh
#      restart` without --attach). An operator-driven interactive launch/attach
#      (ATTACH=1) never sets it, so the wake never fires under the operator's
#      own eyes.
#   2. bridge-run.sh bridge_run_schedule_idle_marker_and_inbox_bootstrap() —
#      when BRIDGE_AUTO_RESTART_WAKE=1 AND this is the first loop iteration
#      (BRIDGE_AGENT_LOOP_RESTART_COUNT==0), widen the once-per-loop-lifetime
#      first-turn inbox-bootstrap inject to fire EVEN WHEN the persistent
#      initial-inbox marker already exists. The same #1199 nudge record is
#      written so the daemon nudge tick (#1199/#1409/#1630) treats the queued
#      set as delivered and does NOT double-fire. A pending NEXT-SESSION.md
#      handoff suppresses the wake (resume drives that turn). An empty queue on
#      a long-lived agent (marker present) injects NOTHING — no per-restart spam.
#
# This pins, in an isolated BRIDGE_HOME:
#   (A) bridge-start.sh --dry-run discriminator: non-attach start carries
#       BRIDGE_AUTO_RESTART_WAKE=1 in tmux_command; --attach start does not.
#   (B) wake decision matrix (via the wake-decision-driver mirroring the
#       production branch against the REAL bridge-lib.sh inject formatters):
#        - auto-restart + open queue + marker present → ONE inbox-bootstrap
#          send + #1199 nudge recorded (the fix);
#        - interactive (auto_restart_wake=0) + open queue + marker present →
#          NO send (invariant 1: never wakes the operator's session);
#        - auto-restart + empty queue + marker present → NO send (invariant 4:
#          no spam on routine restart of a long-lived agent);
#        - auto-restart + empty queue + first-ever launch → ONE minimal
#          session-resumed kick (invariant 4);
#        - first-ever launch + open queue (legacy, no auto signal) → unchanged
#          ONE inbox-bootstrap send + nudge (no regression);
#        - auto-restart + open queue + NEXT-SESSION.md pending → NO send (resume
#          handoff drives the turn);
#        - no-double-fire: the open-queue wake records the comma-joined nudge
#          key so the daemon nudge dedup suppresses a duplicate.
#   (C) source-grep gate: the production guard tokens this driver mirrors are
#       still present in bridge-run.sh / bridge-start.sh (catches divergence).
#
# Footgun #11: the decision body + roster live in tracked file-as-argv helpers
# (scripts/smoke/1639-post-restart-auto-wake-helpers/), no python3/here-string
# heredoc-stdin. Run with /opt/homebrew/bin/bash (Bash 5.x).

set -euo pipefail

SMOKE_NAME="1639-post-restart-auto-wake"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HELPER_DIR="$SCRIPT_DIR/1639-post-restart-auto-wake-helpers"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

DRIVER="$HELPER_DIR/wake-decision-driver.sh"
ROSTER_TEMPLATE="$HELPER_DIR/static-claude-roster.sh"
# CI runners (and any clean shell) do not export BRIDGE_BASH_BIN; fall back to the
# PATH bash so the direct `"$BRIDGE_BASH_BIN" ...` invocations below stay set -u safe.
# Mirrors the `${BRIDGE_BASH_BIN:-$(command -v bash)}` idiom used across the smokes.
BRIDGE_BASH_BIN="${BRIDGE_BASH_BIN:-$(command -v bash)}"

# Parse one KEY=VALUE field out of the driver's stdout.
driver_field() {
  local key="$1"
  local payload="$2"
  printf '%s\n' "$payload" | sed -n "s/^${key}=//p" | head -n 1
}

# --------------------------------------------------------------------------
# (A) bridge-start.sh --dry-run discriminator.
# --------------------------------------------------------------------------
assert_start_dry_run_discriminator() {
  cp "$ROSTER_TEMPLATE" "$BRIDGE_ROSTER_LOCAL_FILE"

  local auto_out interactive_out
  auto_out="$("$BRIDGE_BASH_BIN" "$SMOKE_REPO_ROOT/bridge-start.sh" smoke-1639 --dry-run 2>/dev/null \
    | sed -n 's/^tmux_command=//p' | head -n 1)"
  interactive_out="$("$BRIDGE_BASH_BIN" "$SMOKE_REPO_ROOT/bridge-start.sh" smoke-1639 --attach --dry-run 2>/dev/null \
    | sed -n 's/^tmux_command=//p' | head -n 1)"

  smoke_assert_contains "$auto_out" "BRIDGE_AUTO_RESTART_WAKE=1" \
    "non-attach (auto-restart) start carries BRIDGE_AUTO_RESTART_WAKE=1"
  smoke_assert_not_contains "$interactive_out" "BRIDGE_AUTO_RESTART_WAKE" \
    "interactive --attach start never sets BRIDGE_AUTO_RESTART_WAKE"
}

# --------------------------------------------------------------------------
# (B) wake decision matrix via the driver.
# --------------------------------------------------------------------------
run_driver() {
  # args: <auto_restart_wake> <queue_state: queued|claimed|cron|empty> \
  #       <marker_present> <next_present> [queue_available] [session_identity]
  # Each scenario gets its OWN BRIDGE_ACTIVE_AGENT_DIR so the #2003 restart-wake
  # marker latch (rooted at $BRIDGE_ACTIVE_AGENT_DIR/<agent>/restart-wake) does
  # NOT leak between independent scenarios. The no-double-fire test
  # (run_driver_shared) deliberately shares the dir to exercise the latch.
  local scen_root="$SMOKE_TMP_ROOT/scen-$RANDOM$RANDOM"
  mkdir -p "$scen_root/agents/ag"
  BRIDGE_INJECT_METADATA_ONLY=1 BRIDGE_ACTIVE_AGENT_DIR="$scen_root/agents" \
    "$BRIDGE_BASH_BIN" "$DRIVER" "$SMOKE_REPO_ROOT" "$scen_root/dec" "ag" "$@"
}

# Run the driver against a CALLER-PROVIDED state root + dec dir so two calls can
# share the restart-wake marker latch (same session_identity → suppress) or use
# a fresh session id (→ re-wake). Used by the #2003 no-double-fire assertions.
run_driver_shared() {
  local active_agent_dir="$1" dec_dir="$2"; shift 2
  mkdir -p "$active_agent_dir/ag"
  BRIDGE_INJECT_METADATA_ONLY=1 BRIDGE_ACTIVE_AGENT_DIR="$active_agent_dir" \
    "$BRIDGE_BASH_BIN" "$DRIVER" "$SMOKE_REPO_ROOT" "$dec_dir" "ag" "$@"
}

assert_auto_restart_queued_marker_present_wakes_once() {
  local out
  out="$(run_driver 1 queued 1 0)"
  smoke_assert_eq "1" "$(driver_field SEND_COUNT "$out")" \
    "#1639: auto-restart + queued + marker-present injects exactly one wake"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "event=inbox-bootstrap" \
    "#1639: the auto-restart wake is an inbox-bootstrap event"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "top=7" \
    "#1639 codex r2 [P2]: the surfaced top is the QUEUED top (4th nudge-live-state col), consistent with the recorded key"
  smoke_assert_eq "1" "$(driver_field NUDGE_COUNT "$out")" \
    "#1639: the auto-restart wake records exactly one #1199 nudge (no daemon double-fire)"
  smoke_assert_eq "7,11" "$(driver_field NUDGE_KEY "$out")" \
    "#1639 codex r1 [P2]: nudge key is the full daemon-canonical queued id CSV (not just the top id)"
  smoke_assert_eq "0" "$(driver_field MARKER_WRITTEN "$out")" \
    "#1639: auto-restart wake does not rewrite the existing once-per-lifetime marker"
}

assert_auto_restart_claimed_only_open_work_wakes_no_dedup() {
  local out
  out="$(run_driver 1 claimed 1 0)"
  smoke_assert_eq "1" "$(driver_field SEND_COUNT "$out")" \
    "#1639 codex r3 [P2]: auto-restart with claimed/blocked-only OPEN work still wakes (no queued top, but in-progress work would stall)"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "event=inbox-bootstrap" \
    "#1639 codex r3 [P2]: claimed-only wake surfaces the open task via the find-open fallback"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "top=99" \
    "#1639 codex r3 [P2]: claimed-only wake surfaces the find-open open-set top"
  smoke_assert_eq "0" "$(driver_field NUDGE_COUNT "$out")" \
    "#1639 codex r3 [P2]: claimed-only wake records NO dedup key (daemon nudges only queued; an empty key cannot double-fire)"
}

assert_auto_restart_cron_only_open_work_no_wake() {
  # #1639 Phase-4 codex r4 [BLOCKING]: a cron-dispatch-ONLY queue must NOT wake.
  # nudge-live-state reports 0 (cron excluded) AND the fallback find-open is
  # scoped to non-cron claimed|blocked, so the post-restart path injects nothing.
  # The driver's find-open stub returns the cron row ONLY if the scoping flags
  # are absent, so this case fails loudly if production/driver reverts to the
  # unscoped `find-open --agent` fallback (the r4 regression).
  local out
  out="$(run_driver 1 cron 1 0)"
  smoke_assert_eq "0" "$(driver_field SEND_COUNT "$out")" \
    "#1639 Phase-4 codex r4: auto-restart with a cron-dispatch-ONLY queue does NOT wake (scoped fallback excludes cron, mirroring the daemon's canonical nudge-live-state)"
  smoke_assert_eq "0" "$(driver_field NUDGE_COUNT "$out")" \
    "#1639 Phase-4 codex r4: cron-only no-wake records no dedup key"
}

assert_interactive_queued_marker_present_no_wake() {
  local out
  out="$(run_driver 0 queued 1 0)"
  smoke_assert_eq "0" "$(driver_field SEND_COUNT "$out")" \
    "invariant 1: interactive launch (no auto signal) never auto-wakes the operator's session"
  smoke_assert_eq "0" "$(driver_field NUDGE_COUNT "$out")" \
    "invariant 1: interactive launch records no nudge"
}

assert_auto_restart_empty_queue_marker_present_no_spam() {
  local out
  out="$(run_driver 1 empty 1 0)"
  smoke_assert_eq "0" "$(driver_field SEND_COUNT "$out")" \
    "invariant 4: auto-restart + no open work + long-lived agent injects nothing (no per-restart spam)"
}

assert_auto_restart_empty_queue_first_launch_minimal_kick() {
  local out
  out="$(run_driver 1 empty 0 0)"
  smoke_assert_eq "1" "$(driver_field SEND_COUNT "$out")" \
    "invariant 4: auto-restart + no open work + first-ever launch sends one minimal kick"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "event=session-resumed" \
    "invariant 4: the first-launch no-open-work kick is a session-resumed event"
  smoke_assert_eq "0" "$(driver_field NUDGE_COUNT "$out")" \
    "invariant 4: the no-open-work kick records no nudge (no queued set to dedup)"
}

assert_first_launch_queued_legacy_unchanged() {
  local out
  out="$(run_driver 0 queued 0 0)"
  smoke_assert_eq "1" "$(driver_field SEND_COUNT "$out")" \
    "no regression: first-ever launch with queued work still injects the inbox-bootstrap"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "event=inbox-bootstrap" \
    "no regression: legacy first-launch wake stays an inbox-bootstrap event"
  smoke_assert_eq "1" "$(driver_field MARKER_WRITTEN "$out")" \
    "no regression: first-ever launch writes the once-per-lifetime marker"
}

# --------------------------------------------------------------------------
# (B7-B9) #2003 NEXT-SESSION restart-wake matrix.
# --------------------------------------------------------------------------
assert_next_session_queued_handoff_wakes_queue_backed() {
  # auto-restart + NEXT-SESSION + a handoff task ALREADY queued (the
  # SessionStart hook ran first): ONE inbox-bootstrap wake + the #1199 nudge
  # key = the handoff task id. Queue-backed → daemon dedup skips it.
  local out
  out="$(run_driver 1 queued 1 1 1)"
  smoke_assert_eq "1" "$(driver_field SEND_COUNT "$out")" \
    "#2003: NEXT-SESSION + already-queued handoff injects exactly one wake (no longer suppressed)"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "event=inbox-bootstrap" \
    "#2003: the queued-handoff wake is a queue-backed inbox-bootstrap"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "top=55" \
    "#2003: the surfaced top is the existing queued handoff task id"
  smoke_assert_eq "1" "$(driver_field NUDGE_COUNT "$out")" \
    "#2003: the queue-backed handoff wake records exactly one #1199 nudge (daemon dedup)"
}

assert_next_session_no_task_creates_and_wakes() {
  # auto-restart + NEXT-SESSION + NO queued task: bridge-run finds/creates ONE
  # handoff task (same digest/title contract as the SessionStart hook) → one
  # inbox-bootstrap wake + nudge recorded against the created task id.
  local out
  out="$(run_driver 1 empty 1 1 1)"
  smoke_assert_eq "1" "$(driver_field SEND_COUNT "$out")" \
    "#2003: NEXT-SESSION + no queued task → bridge-run creates a handoff task and wakes exactly once"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "event=inbox-bootstrap" \
    "#2003: the created-handoff wake is a queue-backed inbox-bootstrap"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "top=77" \
    "#2003: the surfaced top is the just-created handoff task id"
  smoke_assert_eq "1" "$(driver_field NUDGE_COUNT "$out")" \
    "#2003: the created-handoff wake records exactly one #1199 nudge"
}

assert_next_session_queue_unavailable_fallback_kick() {
  # auto-restart + NEXT-SESSION + queue create/find UNAVAILABLE: ONE
  # handoff-resume fallback kick, NO #1199 key (queue-less), latched on the
  # per-session restart-wake marker.
  local out
  out="$(run_driver 1 empty 1 1 0)"
  smoke_assert_eq "1" "$(driver_field SEND_COUNT "$out")" \
    "#2003: NEXT-SESSION + queue unavailable → one fallback handoff-resume kick (never sits idle)"
  smoke_assert_contains "$(driver_field SEND_TEXT "$out")" "event=handoff-resume" \
    "#2003: the queue-less handoff wake is a handoff-resume event"
  smoke_assert_eq "0" "$(driver_field NUDGE_COUNT "$out")" \
    "#2003: the queue-less handoff wake records NO #1199 key (nothing queued to dedup)"
}

assert_next_session_fallback_no_double_fire() {
  # Same launched session (same session_identity + same handoff digest): the
  # queue-less fallback wakes ONCE then suppresses on retry (the restart-wake
  # marker latch). A NEW session (new id) with the same handoff MAY wake again.
  local shared_root dec out1 out2 out3
  shared_root="$SMOKE_TMP_ROOT/ddf-$RANDOM$RANDOM/agents"
  dec="$SMOKE_TMP_ROOT/ddf-dec-$RANDOM$RANDOM"
  out1="$(run_driver_shared "$shared_root" "$dec" 1 empty 1 1 0 sess-A)"
  out2="$(run_driver_shared "$shared_root" "$dec" 1 empty 1 1 0 sess-A)"
  out3="$(run_driver_shared "$shared_root" "$dec" 1 empty 1 1 0 sess-B)"
  smoke_assert_eq "1" "$(driver_field SEND_COUNT "$out1")" \
    "#2003 no-double-fire: first queue-less handoff wake fires once"
  smoke_assert_eq "0" "$(driver_field SEND_COUNT "$out2")" \
    "#2003 no-double-fire: a retry in the SAME launched session does NOT re-wake (restart-wake marker latch)"
  smoke_assert_eq "1" "$(driver_field SEND_COUNT "$out3")" \
    "#2003: a NEW launched session (new session id) with the same handoff MAY wake again"
}

# --------------------------------------------------------------------------
# (C) source-grep gate — the production guards this driver mirrors must exist.
# --------------------------------------------------------------------------
assert_production_guards_present() {
  local run_sh="$SMOKE_REPO_ROOT/bridge-run.sh"
  local start_sh="$SMOKE_REPO_ROOT/bridge-start.sh"
  local state_sh="$SMOKE_REPO_ROOT/lib/bridge-state.sh"
  local hook_py="$SMOKE_REPO_ROOT/hooks/bridge_hook_common.py"

  smoke_assert_contains "$(cat "$start_sh")" 'BRIDGE_AUTO_RESTART_WAKE=1 ${SESSION_CMD}' \
    "bridge-start.sh still injects BRIDGE_AUTO_RESTART_WAKE into SESSION_CMD"
  smoke_assert_contains "$(cat "$start_sh")" 'if [[ $ATTACH -eq 0 ]]; then' \
    "bridge-start.sh still gates the auto-restart signal on ATTACH==0"
  smoke_assert_contains "$(cat "$run_sh")" 'BRIDGE_AUTO_RESTART_WAKE:-0' \
    "bridge-run.sh still reads BRIDGE_AUTO_RESTART_WAKE"
  smoke_assert_contains "$(cat "$run_sh")" 'BRIDGE_AGENT_LOOP_RESTART_COUNT:-0' \
    "bridge-run.sh still gates the wake on the first loop iteration"
  smoke_assert_contains "$(cat "$run_sh")" '[[ "$auto_restart_wake" == "1" ]]' \
    "bridge-run.sh still widens the inject gate on the auto-restart signal"
  smoke_assert_contains "$(cat "$run_sh")" 'session-resumed' \
    "bridge-run.sh still emits the minimal session-resumed kick branch"
  smoke_assert_contains "$(cat "$run_sh")" 'nudge-live-state' \
    "bridge-run.sh derives the #1199 dedup key from the daemon-canonical nudge-live-state emitter (codex r1 [P2])"
  smoke_assert_contains "$(cat "$run_sh")" 'cut -f4' \
    "bridge-run.sh sources the surfaced top from nudge-live-state with_top_task (consistent with the dedup key — codex r2 [P2])"
  smoke_assert_contains "$(cat "$run_sh")" 'if [[ -n "$queued_top" ]]; then' \
    "bridge-run.sh branches on queued_top, falling back to the open-set probe for claimed/blocked work (codex r3 [P2])"
  smoke_assert_contains "$(cat "$run_sh")" '--status-filter claimed --status-filter blocked' \
    "bridge-run.sh scopes the post-restart fallback to claimed|blocked open work (#1639 Phase-4 codex r4 — guards against a revert to the unscoped find-open)"
  smoke_assert_contains "$(cat "$run_sh")" "--exclude-title-prefix '[cron-dispatch]'" \
    "bridge-run.sh excludes cron-dispatch rows from the post-restart fallback so a cron-only queue cannot spuriously wake (#1639 Phase-4 codex r4)"
  # --- #2003 production-token gate -----------------------------------------
  smoke_assert_contains "$(cat "$run_sh")" 'bridge_run_handoff_task_find_or_create' \
    "bridge-run.sh makes a NEXT-SESSION restart wake queue-backed via the handoff find/create helper (#2003 step 4)"
  # The handoff find-or-create MUST be ATOMIC (upsert-open), NOT racy
  # find-open+create — both this helper and the SessionStart hook can run on the
  # same handoff concurrently (codex review BLOCKING: TOCTOU → duplicate tasks).
  smoke_assert_contains "$(cat "$state_sh")" 'upsert-open' \
    "lib/bridge-state.sh::bridge_run_handoff_task_find_or_create uses atomic upsert-open (no find-open+create TOCTOU race)"
  smoke_assert_contains "$(cat "$hook_py")" 'upsert-open' \
    "hooks/bridge_hook_common.py::_enqueue_handoff_pending uses atomic upsert-open so the hook + restart paths converge on ONE handoff task (#2003 race fix)"
  smoke_assert_contains "$(cat "$run_sh")" 'bridge_agent_restart_wake_marker_file' \
    "bridge-run.sh latches the queue-less handoff/first-launch wake on a per-session restart-wake marker (#2003 idempotency layer 2)"
  smoke_assert_contains "$(cat "$run_sh")" 'handoff-resume' \
    "bridge-run.sh emits the handoff-resume kick when the queue is unreachable but a NEXT-SESSION handoff is present (#2003 step 5)"
  smoke_assert_contains "$(cat "$run_sh")" 'session_identity' \
    "bridge-run.sh builds the #2003 idempotency key from the launched-session identity (refreshed Claude id / tmux+nonce)"
  # The blanket whole-inject suppression `if [[ ! -f "$next_file" ]] \` (the
  # OLD #1639 gate) MUST be gone — a present NEXT-SESSION.md now drives a
  # queue-backed wake, not suppression. Match the exact old code statement (the
  # `if [[ ! -f "$next_file" ]]` followed by a line-continuation `\`), not the
  # explanatory comment that quotes the old token in backticks.
  if grep -qE 'if \[\[ ! -f "\$next_file" \]\] \\$' "$run_sh"; then
    smoke_fail "#2003 regression: bridge-run.sh still suppresses the post-restart inject on a present NEXT-SESSION.md (the blanket 'if [[ ! -f \$next_file ]]' gate must be removed)"
  fi
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  smoke_assert_file_exists "$DRIVER" "wake-decision driver present"
  smoke_assert_file_exists "$ROSTER_TEMPLATE" "static-claude roster template present"

  smoke_run "(A) bridge-start.sh --dry-run auto-restart discriminator" assert_start_dry_run_discriminator
  smoke_run "(B1) auto-restart + queued + marker → one wake + nudge"   assert_auto_restart_queued_marker_present_wakes_once
  smoke_run "(B1b) auto-restart + claimed-only open → wake, no dedup"  assert_auto_restart_claimed_only_open_work_wakes_no_dedup
  smoke_run "(B1c) auto-restart + cron-only open → NO wake (r4)"       assert_auto_restart_cron_only_open_work_no_wake
  smoke_run "(B2) interactive + queued + marker → no auto-wake"        assert_interactive_queued_marker_present_no_wake
  smoke_run "(B3) auto-restart + empty queue + marker → no spam"       assert_auto_restart_empty_queue_marker_present_no_spam
  smoke_run "(B4) auto-restart + empty queue + first launch → kick"    assert_auto_restart_empty_queue_first_launch_minimal_kick
  smoke_run "(B5) first launch + queued (legacy) → unchanged"          assert_first_launch_queued_legacy_unchanged
  smoke_run "(B7) #2003 NEXT + already-queued handoff → one wake+nudge" assert_next_session_queued_handoff_wakes_queue_backed
  smoke_run "(B8) #2003 NEXT + no task → create + one wake+nudge"       assert_next_session_no_task_creates_and_wakes
  smoke_run "(B9) #2003 NEXT + queue unavailable → one fallback kick"   assert_next_session_queue_unavailable_fallback_kick
  smoke_run "(B10) #2003 fallback no-double-fire + cross-session rewake" assert_next_session_fallback_no_double_fire
  smoke_run "(C) production guard tokens present (anti-divergence)"    assert_production_guards_present
  smoke_log "passed"
}

main "$@"
