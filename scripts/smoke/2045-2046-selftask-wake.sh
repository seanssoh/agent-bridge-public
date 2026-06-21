#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2045-2046-selftask-wake.sh
#
# Issues #2045 + #2046 -- self/loopback task-create wake latency (two facets of
# ONE wake-path bug). A task enqueued via the LOCAL `task create` path with
# `--from X --to X` (the same agent is creator AND assignee, e.g. a Discord
# thread sub-session handing off to its own main session) got NO seconds-latency
# wake -- only the daemon's slow periodic nudge (minutes). Cross-agent tasks
# (--from X --to Y) woke in ~1s.
#
#   #2046 (create-time push): bridge-task.sh cmd_create (and bridge-bundle.sh)
#       guarded the create-time push `bridge_dispatch_notification` behind
#       `if [[ "$target" != "$actor" ]]`, so a self-task got no push at all.
#       Fix: drop the from!=to guard so the push fires for a self-task too. The
#       TARGET-session busy gate inside bridge_tmux_send_and_submit
#       (bridge_tmux_session_inject_busy) is what prevents a mid-turn agent from
#       nudging ITSELF into its own live composer -- a busy target spools, an
#       idle target (thread->main) wakes in seconds.
#
#   #2045 (fresh-arrival marker): the one-shot fresh-arrival fast-wake marker
#       (#1630) was posted ONLY by the A2A receiver, so a LOCAL self-task never
#       got it and stayed under the ~60s redelivery-age gate. Fix: bridge-queue.py
#       cmd_create now posts the SAME marker on every successful local enqueue,
#       giving a loopback task the one-tick age-gate exemption.
#
# This smoke drives the REAL bridge-queue.py create + daemon-step, and the REAL
# bridge-task.sh cmd_create guard decision, end to end against an isolated
# BRIDGE_HOME. No live Claude/Codex and no tmux: cmd_create's wake-path helpers
# are stubbed with recorders so the GUARD DECISION (does the create-time push
# fire for a self-task?) is the unit under test, while the enqueue is real.
#
# Test plan:
#   A1 (#2045): a self/loopback create posts the fresh-arrival marker; the
#       daemon-step then fast-wakes the fresh task on this tick.
#   A2 (#2045 mutation): with the marker absent (writer reverted), the same
#       fresh self-task is suppressed under the age gate.
#   A3 (#2045): a cross-agent create does NOT post the marker — the marker is
#       scoped to the loopback (actor==assigned_to) case, so #1014's age gate +
#       the redundant-active-agent gate stay intact for normal local tasks.
#   B1 (#2046): cmd_create fires the create-time push for a SELF-task.
#   B2 (#2046 mutation): re-introducing the from!=to guard makes the SAME
#       self-task skip the push.
#   B3 (#2046): the cross-agent create still fires the push (parity).
#   C1 (negative): the push routes through bridge_tmux_send_and_submit, whose
#       TARGET-session inject-busy gate spools (does not type) a mid-turn target.
#   T  (teeth): the from!=to guard is gone from both cmd_create and the bundle
#       push, cmd_create posts the marker, and the busy-gate safety is intact.
#
# Footgun #11: every python3 subprocess reads inputs via argv or file paths,
# never stdin; no here-string into a bridge function.

set -euo pipefail

if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:2045-2046-selftask-wake] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="2045-2046-selftask-wake"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"

export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=60
export BRIDGE_TASK_IDLE_NUDGE_SECONDS=30
export BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS=1

FRESH_ARRIVAL_DIR="$BRIDGE_STATE_DIR/queue/fresh-arrival"
TASK_SH="$REPO_ROOT/bridge-task.sh"
BUNDLE_SH="$REPO_ROOT/bridge-bundle.sh"
QUEUE_PY="$REPO_ROOT/bridge-queue.py"
NOTIFY_LIB="$REPO_ROOT/lib/bridge-notify.sh"
TMUX_LIB="$REPO_ROOT/lib/bridge-tmux.sh"

smoke_assert_file_exists "$TASK_SH" "bridge-task.sh present"
smoke_assert_file_exists "$BUNDLE_SH" "bridge-bundle.sh present"
smoke_assert_file_exists "$QUEUE_PY" "bridge-queue.py present"

# --- shared helpers --------------------------------------------------------

# create_via_queue <from> <to> <title> -> echoes the new task id (REAL enqueue).
create_via_queue() {
  local from="$1" to="$2" title="$3"
  local out
  out="$(python3 "$QUEUE_PY" create \
    --to "$to" --from "$from" --title "$title" --body "body for $title" \
    --format shell)"
  local _src_tmp
  _src_tmp="$(mktemp "${SMOKE_TMP_ROOT:-/tmp}/selftask-create.XXXXXX")"
  printf '%s\n' "$out" >"$_src_tmp"
  # shellcheck disable=SC1090
  source "$_src_tmp"
  rm -f "$_src_tmp"
  printf '%s' "$TASK_ID"
  unset TASK_ID
}

write_snapshot() {
  local file="$1" agent="$2" session="$3" active="$4" activity_ts="$5"
  {
    printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\tprompt_ready_ts\tprompt_ready_session\tprompt_ready_source\tactivity_state\n'
    printf '%s\tclaude\t%s\t/tmp/x\t%s\t%s\t\t\t\t\n' "$agent" "$session" "$active" "$activity_ts"
  } >"$file"
}

run_daemon_step() {
  local snapshot="$1"
  local ready_file="$SMOKE_TMP_ROOT/ready-agents.txt"
  : >"$ready_file"
  python3 "$QUEUE_PY" daemon-step \
    --snapshot "$snapshot" \
    --ready-agents-file "$ready_file" \
    --lease-seconds 900 \
    --heartbeat-window 300 \
    --idle-threshold "$BRIDGE_TASK_IDLE_NUDGE_SECONDS" \
    --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS" \
    --admin-agent patch \
    --format tsv 2>/dev/null
}

# ===========================================================================
# Facet A (#2045): the LOCAL create path posts the fresh-arrival marker.
# ===========================================================================

smoke_run "A1 (#2045) self/loopback create posts the marker + daemon fast-wakes" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID_A1="$(create_via_queue syrs-calendar syrs-calendar 'thread-to-main self-task')"
  smoke_assert_file_exists "$FRESH_ARRIVAL_DIR/$TID_A1" \
    "A1 local self-task create posted the fresh-arrival marker for $TID_A1"
  snap="$SMOKE_TMP_ROOT/snap-a1.tsv"
  write_snapshot "$snap" syrs-calendar sess-a1 1 "$(( $(date +%s) - 300 ))"
  out="$(run_daemon_step "$snap")"
  smoke_assert_contains "$out" "syrs-calendar" "A1 daemon emits a nudge for the loopback target this tick"
  smoke_assert_contains "$out" "$TID_A1" "A1 nudge carries the fresh self-task id $TID_A1"
  [[ ! -e "$FRESH_ARRIVAL_DIR/$TID_A1" ]] || smoke_fail "A1 marker $TID_A1 must be consumed (one-shot)"
}

smoke_run "A2 (#2045 mutation) marker absent -> fresh self-task suppressed (age gate intact)" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID_A2="$(create_via_queue syrs-calendar syrs-calendar 'self-task no marker')"
  rm -f "$FRESH_ARRIVAL_DIR/$TID_A2"
  snap="$SMOKE_TMP_ROOT/snap-a2.tsv"
  write_snapshot "$snap" syrs-calendar sess-a2 1 "$(( $(date +%s) - 300 ))"
  out="$(run_daemon_step "$snap")"
  smoke_assert_not_contains "$out" "$TID_A2" \
    "A2 without the marker the fresh self-task is held by the ~60s age gate (mutation proof)"
}

smoke_run "A3 (#2045) cross-agent create does NOT post the marker (loopback-scoped)" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID_A3="$(create_via_queue syrs-calendar other-agent 'cross-agent task')"
  if [[ -e "$FRESH_ARRIVAL_DIR/$TID_A3" ]]; then
    smoke_fail "A3 cross-agent create must NOT post the fresh-arrival marker — the marker is scoped to the loopback (actor==assigned_to) case; a cross-agent local task is delivered by the create-time push (#2046) and must stay under the ~60s age gate (#1014) + the redundant-active-agent gate (else nudge-task-age-gate / nudge-redundant-active-agent regress)"
  fi
}

# ===========================================================================
# Facet B (#2046): cmd_create fires the create-time push for a self-task.
#
# Source the function-only prefix of bridge-task.sh (everything before the
# trailing top-level dispatch at `COMMAND=`), then OVERRIDE the wake-path
# helpers with recorders so the guard decision is the unit under test. The
# enqueue (bridge_queue_source_shell -> real bridge-queue.py) stays REAL so
# TASK_ID is populated exactly as in production.
# ===========================================================================

# Build a function-only copy: drop the trailing top-level dispatch (from the
# `COMMAND="${1:-}"` line on), and also drop the copy's own `set -euo pipefail`,
# `SCRIPT_DIR=` resolution, and `source .../bridge-lib.sh` -- the harness sources
# bridge-lib.sh once from the REPO and pins SCRIPT_DIR there, so the copy (in a
# temp dir) does not try to re-resolve bridge-lib.sh from the wrong directory.
TASK_FUNCS="$SMOKE_TMP_ROOT/bridge-task-funcs.sh"
awk '
  BEGIN{p=1}
  /^COMMAND="\$\{1:-\}"/{p=0}
  !p{next}
  /^set -euo pipefail/{next}
  /^SCRIPT_DIR=/{next}
  /source "\$SCRIPT_DIR\/bridge-lib.sh"/{next}
  {print}
' "$TASK_SH" >"$TASK_FUNCS"
smoke_assert_file_exists "$TASK_FUNCS" "function-only bridge-task.sh copy built"

# Source bridge-lib.sh ONCE from the repo (defines the helpers cmd_create's
# stubs must override) and pin SCRIPT_DIR at the repo so any residual repo-path
# reference in the copy resolves correctly.
SCRIPT_DIR="$REPO_ROOT"
export SCRIPT_DIR
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1

DISPATCH_LOG="$SMOKE_TMP_ROOT/dispatch.log"

# Drive one cmd_create in a SUBSHELL with stubbed wake-path helpers. Appends
# "DISPATCHED <target>" to the dispatch log iff the create-time push fired.
# arg1=from arg2=to arg3=title arg4=reintroduce_guard(0|1)
drive_cmd_create() {
  local c_from="$1" c_to="$2" c_title="$3" c_guard="$4"
  (
    set +e
    # shellcheck source=/dev/null
    source "$TASK_FUNCS" >/dev/null 2>&1

    # These stubs are invoked INDIRECTLY by the sourced cmd_create (shellcheck
    # cannot see the indirection), so SC2329 (never-invoked) is a false positive.
    # shellcheck disable=SC2329
    ensure_roster_loaded() { :; }
    # shellcheck disable=SC2329
    bridge_require_agent() { :; }
    # shellcheck disable=SC2329
    infer_actor_if_possible() { printf '%s' "$1"; }
    # shellcheck disable=SC2329
    emit_inferred_actor_hint() { :; }
    # shellcheck disable=SC2329
    bridge_agent_is_active() { return 0; }
    # shellcheck disable=SC2329
    bridge_agent_engine() { printf 'claude'; }
    # shellcheck disable=SC2329
    bridge_agent_prompt_guard_enabled() { return 1; }

    if [[ "$c_guard" == "1" ]]; then
      # MUTATION: re-wrap the push in the pre-fix from!=to guard so the same
      # self-task skips it -- equivalent to the deleted target!=actor gate.
      # shellcheck disable=SC2329
      bridge_dispatch_notification() {
        local _t="$1"
        if [[ "$_t" != "$c_from" ]]; then
          printf 'DISPATCHED %s\n' "$_t" >>"$DISPATCH_LOG"
        fi
        return 0
      }
    else
      # shellcheck disable=SC2329
      bridge_dispatch_notification() {
        printf 'DISPATCHED %s\n' "$1" >>"$DISPATCH_LOG"
        return 0
      }
    fi

    cmd_create --from "$c_from" --to "$c_to" --title "$c_title" --body "b" >/dev/null 2>&1
  )
}

smoke_run "B1 (#2046) self-task create fires the create-time push (guard removed)" : ; {
  : >"$DISPATCH_LOG"
  drive_cmd_create syrs-calendar syrs-calendar 'B1 self push' 0 || true
  smoke_assert_contains "$(cat "$DISPATCH_LOG")" "DISPATCHED syrs-calendar" \
    "B1 cmd_create dispatched the create-time push for a self-task (target==actor)"
}

smoke_run "B2 (#2046 mutation) re-add the from!=to guard -> self-task skips the push" : ; {
  : >"$DISPATCH_LOG"
  drive_cmd_create syrs-calendar syrs-calendar 'B2 self push guarded' 1 || true
  smoke_assert_not_contains "$(cat "$DISPATCH_LOG")" "DISPATCHED" \
    "B2 with the from!=to guard the self-task gets NO push (proves B1 is the guard removal)"
}

smoke_run "B3 (#2046) cross-agent create still fires the push (parity)" : ; {
  : >"$DISPATCH_LOG"
  drive_cmd_create syrs-calendar other-agent 'B3 cross push' 0 || true
  smoke_assert_contains "$(cat "$DISPATCH_LOG")" "DISPATCHED other-agent" \
    "B3 cross-agent push unchanged (idle target woken)"
}

# ===========================================================================
# C1 (negative): the push goes through the TARGET-session busy gate, so a
# busy/mid-turn self-target is spooled, never typed into its live composer.
# This is the structural contract that keeps "no self-nudge-mid-turn".
# ===========================================================================

smoke_run "C1 (negative) create-time push routes through the target busy gate (no self-interrupt)" : ; {
  grep -q 'bridge_tmux_send_and_submit "$session" "$engine" "$text" "$agent"' "$NOTIFY_LIB" \
    || smoke_fail "C1 bridge_dispatch_notification must wake via bridge_tmux_send_and_submit (target busy gate)"
  grep -q 'bridge_tmux_session_inject_busy' "$TMUX_LIB" \
    || smoke_fail "C1 bridge_tmux_send_and_submit must consult bridge_tmux_session_inject_busy (target busy gate)"
  grep -q 'bridge_tmux_pending_attention_append "$spool_agent" "$text"' "$TMUX_LIB" \
    || smoke_fail "C1 a busy target must SPOOL the nudge (pending-attention), not type it into the live composer"
}

# C1b: behavioral proof of the busy gate. Source bridge_tmux_session_inject_busy
# from the real lib, stub its leaf probes, and assert: a target with pending
# composer input reports BUSY (-> spool, never typed), a Claude target mid-turn
# (live "Working" banner) reports BUSY, and an idle target (thread->main) reports
# NOT busy (-> the push fires, seconds-latency wake). This is the mechanism that
# distinguishes a legit idle-loopback wake from a self-nudge-mid-turn.
smoke_run "C1b (behavioral) inject_busy: pending-input + Claude mid-turn => busy (spool); idle => wake" : ; {
  (
    set +e
    # shellcheck source=lib/bridge-tmux.sh disable=SC1091
    source "$TMUX_LIB" >/dev/null 2>&1 || true
    declare -F bridge_tmux_session_inject_busy >/dev/null \
      || smoke_fail "C1b bridge_tmux_session_inject_busy not defined after sourcing lib/bridge-tmux.sh"

    # Leaf-probe stubs (overridden AFTER the source so they win).
    # shellcheck disable=SC2329
    bridge_capture_recent() { printf '%s' "${_C1B_CAPTURE:-}"; }
    # shellcheck disable=SC2329
    bridge_tmux_session_attached_count() { printf '0'; }
    # shellcheck disable=SC2329
    bridge_tmux_session_recent_keypress() { return 1; }

    # Case 1: pending composer input -> BUSY (rc 0).
    # shellcheck disable=SC2329
    bridge_tmux_session_has_pending_input() { return 0; }
    if ! bridge_tmux_session_inject_busy sess claude 10; then
      smoke_fail "C1b pending-input target must report BUSY (spool, not type)"
    fi

    # Case 2: no pending input, Claude live mid-turn banner -> BUSY (rc 0).
    # shellcheck disable=SC2329
    bridge_tmux_session_has_pending_input() { return 1; }
    _C1B_CAPTURE="Working (esc to interrupt)"
    # shellcheck disable=SC2329
    bridge_tmux_claude_capture_is_midturn() { [[ "$1" == *"esc to interrupt"* ]]; }
    if ! bridge_tmux_session_inject_busy sess claude 10; then
      smoke_fail "C1b Claude mid-turn banner target must report BUSY (spool, not type)"
    fi

    # Case 3: idle target (no pending input, clean prompt, no keypress) -> NOT
    # busy (rc 1) -> the create-time push fires and wakes a thread->main self-task.
    _C1B_CAPTURE="clean prompt only"
    # shellcheck disable=SC2329
    bridge_tmux_claude_capture_is_midturn() { return 1; }
    if bridge_tmux_session_inject_busy sess claude 10; then
      smoke_fail "C1b idle target must report NOT busy so the loopback push wakes it in seconds"
    fi
  ) || exit 1
}

# C1c (documented residual, #1409-class): the mid-turn BANNER gate is Claude-only
# -- Codex handles its banner in its own submit path, so there is NO Codex
# mid-turn detector in bridge_tmux_session_inject_busy. This bounded residual is
# carried over UNCHANGED from the cross-agent path (issue #2046 scopes it out);
# making the self-task path reuse the identical rails neither widens nor narrows
# it. Pin the Claude-scoping so a future reader sees it is deliberate and a
# future PR that claims a Codex mid-turn gate must update this assertion.
smoke_run "C1c (documented residual) mid-turn banner gate is Claude-scoped (Codex residual is pre-existing)" : ; {
  if ! grep -q 'if \[\[ "$engine" == "claude" \]\]; then' "$TMUX_LIB"; then
    smoke_fail "C1c expected the inject_busy mid-turn banner gate to be Claude-scoped (engine guard moved?)"
  fi
  grep -q 'this gate stays claude-specific' "$TMUX_LIB" \
    || smoke_fail "C1c the Claude-only mid-turn rationale comment must remain (documents the bounded Codex residual)"
}

# ===========================================================================
# Teeth: pin both fixes structurally.
# ===========================================================================

smoke_run "T teeth: guard removed in cmd_create + bundle, marker posted, busy gate intact" : ; {
  if grep -A1 'notice_message="agb inbox \${target}"' "$TASK_SH" | grep -q '\[\[ "\$target" != "\$actor" \]\]'; then
    smoke_fail "teeth: cmd_create still guards the create-time push behind target!=actor"
  fi
  if grep -Eq 'if \[\[ "\$target" != "\$actor" \]\]; then' "$BUNDLE_SH"; then
    smoke_fail "teeth: bridge-bundle.sh still guards its handoff push behind target!=actor"
  fi
  grep -q 'def post_fresh_arrival_marker' "$QUEUE_PY" \
    || smoke_fail "teeth: bridge-queue.py must define post_fresh_arrival_marker (local marker writer)"
  grep -q 'post_fresh_arrival_marker(task_id)' "$QUEUE_PY" \
    || smoke_fail "teeth: bridge-queue.py cmd_create must call post_fresh_arrival_marker(task_id)"
  grep -q '"queue" / "fresh-arrival"' "$QUEUE_PY" \
    || smoke_fail "teeth: bridge-queue.py marker dir must be queue/fresh-arrival (same SSOT as the receiver)"
  grep -q 'bridge_tmux_session_inject_busy' "$TMUX_LIB" \
    || smoke_fail "teeth: bridge_tmux_send_and_submit must keep the target inject-busy gate"
}

smoke_log "all checks passed"
