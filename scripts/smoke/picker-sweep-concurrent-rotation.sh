#!/usr/bin/env bash
# scripts/smoke/picker-sweep-concurrent-rotation.sh — cross-process
# rotation-lock regression smoke for picker-sweep (codex PR #971 r1
# BLOCKING fix).
#
# Without the cross-process lock in scripts/picker-sweep.sh, two
# picker-sweep processes that co-fire against the same BRIDGE_HOME both
# pass the cooldown due-check (the cooldown state file is only WRITTEN
# AFTER a successful rotate call) and both invoke `bridge-auth.sh
# claude-token rotate` — burning two tokens for one rate-limit event.
#
# This smoke proves the lock works by:
#   1. Planting a rate-limit picker on a single agent so each sweep
#      would naturally try to rotate.
#   2. Stubbing the rotate seam with a script that records each invocation
#      to a counter file under flock, then sleeps long enough that two
#      concurrent sweeps would land inside the critical section without
#      serialisation.
#   3. Launching two `bash scripts/picker-sweep.sh` processes in parallel,
#      waiting for both to complete cleanly, and asserting exactly ONE
#      rotate-stub invocation.
#
# The smoke runs the parallel launch 5 times to reduce the chance that
# a scheduler quirk hides a race window during the very first run.
#
# Bug-detection guarantee: removing the lock (or making
# _psw_acquire_rotation_lock unconditionally return 0) MUST cause this
# smoke to fail. See Test 8 manual verification step in the PR brief.

set -euo pipefail

SMOKE_NAME="picker-sweep-concurrent-rotation"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
    smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
PICKER_SWEEP="$REPO_ROOT/scripts/picker-sweep.sh"
[[ -x "$PICKER_SWEEP" ]] || smoke_fail "picker-sweep.sh missing or not executable: $PICKER_SWEEP"

FIXTURE_DIR="$SMOKE_TMP_ROOT/fixtures"
mkdir -p "$FIXTURE_DIR"

# How many parallel-launch rounds to run. Race detection needs reps;
# this is the operator-overridable knob if a flake ever surfaces.
ROUNDS="${BRIDGE_PICKER_SWEEP_CONCURRENT_SMOKE_ROUNDS:-5}"
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || ROUNDS=5

# How long the rotate stub sleeps to widen the critical-section race
# window. 250ms is enough to make two processes' due-check + rotate
# overlap on any sane scheduler, while keeping the whole smoke under
# ~5s total. Tunable for slow VMs.
ROTATE_SLEEP_SECS="${BRIDGE_PICKER_SWEEP_CONCURRENT_SMOKE_SLEEP:-0.25}"

# ---------------------------------------------------------------------------
# Mock harness. Each sweep gets the SAME mock function names exported
# from the same MOCK_LIB; we wire seams via env vars, and the rotate
# stub records calls to a shared file under FIXTURE_DIR (the only
# inter-process channel).
# ---------------------------------------------------------------------------

# Files inspected after each round.
SESSIONS_FILE="$FIXTURE_DIR/sessions"
PANE_FILE="$FIXTURE_DIR/pane-stuck-agent"
ROTATE_COUNT_FILE="$FIXTURE_DIR/rotate-count"
ROTATE_LOG="$FIXTURE_DIR/rotate-calls.log"
SWEEP_LOG_A="$FIXTURE_DIR/sweep-a.log"
SWEEP_LOG_B="$FIXTURE_DIR/sweep-b.log"

MOCK_LIB="$FIXTURE_DIR/mock-lib.sh"
cat >"$MOCK_LIB" <<'MOCK_EOF'
#!/usr/bin/env bash
# Test seams for the concurrent-rotation smoke. Sourced by the sweep
# subprocess shells so they expose the right function names.

mock_list_sessions() {
    [[ -f "$SESSIONS_FILE" ]] && cat "$SESSIONS_FILE"
}

mock_capture_pane() {
    local target="$1"
    [[ -f "$FIXTURE_DIR/pane-$target" ]] && cat "$FIXTURE_DIR/pane-$target"
}

mock_send_enter() {
    # No-op for this smoke; we only care about rotation count.
    :
}

mock_send_option() {
    :
}

mock_create_task() {
    # Swallow task creation — irrelevant to the race assertion.
    :
}

# Race-window widener: each call sleeps ROTATE_SLEEP_SECS to ensure
# two concurrent processes' critical sections overlap. Records its
# own PID + a timestamp so the smoke can confirm both sweeps actually
# attempted to enter the rotation branch in the no-lock counterfactual.
#
# Counter is incremented under a flock-equivalent (mkdir lock) so the
# count is accurate even if the rotate function was somehow called
# concurrently — the count assertion is the actual race-detection
# signal, not just a side effect of fewer calls.
mock_rotate_claude_token() {
    local agent="$1" lock_dir="$FIXTURE_DIR/.counter-lock"
    local count=0

    # Record the entry timestamp BEFORE the sleep so the smoke can see
    # whether both sweeps actually entered this function.
    printf '%s pid=%s agent=%s entered\n' "$(date +%s.%N)" "$$" "$agent" >> "$ROTATE_LOG"

    sleep "$ROTATE_SLEEP_SECS"

    # Atomic increment of the counter file under mkdir-lock. We retry
    # for up to ~2s — if the counter lock is contested longer than
    # that, something is wrong with the smoke itself.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if mkdir "$lock_dir" 2>/dev/null; then
            count="$(cat "$ROTATE_COUNT_FILE" 2>/dev/null || printf '0')"
            count=$(( count + 1 ))
            printf '%s\n' "$count" > "$ROTATE_COUNT_FILE"
            rm -rf "$lock_dir"
            break
        fi
        sleep 0.05
    done

    printf '{"status":"rotated","active_token_id":"next-%s","reason":"smoke"}\n' "$count"
    return 0
}

export -f mock_list_sessions mock_capture_pane mock_send_enter mock_send_option mock_create_task mock_rotate_claude_token
MOCK_EOF

# Build the per-sweep wrapper. It sources MOCK_LIB, exports seams,
# then execs picker-sweep.sh. We use a wrapper file (rather than a
# string passed to `bash -c`) so each subprocess starts from a clean
# parent env and so the harness is easy to inspect if the smoke fails.
SWEEP_WRAPPER="$FIXTURE_DIR/run-sweep.sh"
cat >"$SWEEP_WRAPPER" <<'WRAP_EOF'
#!/usr/bin/env bash
set -uo pipefail

# Inherit FIXTURE_DIR, ROTATE_COUNT_FILE, ROTATE_LOG, SESSIONS_FILE,
# ROTATE_SLEEP_SECS, BRIDGE_HOME, etc. from the caller's exported env.
# shellcheck source=/dev/null
source "$FIXTURE_DIR/mock-lib.sh"

export BRIDGE_PICKER_SWEEP_LIST_SESSIONS_FN=mock_list_sessions
export BRIDGE_PICKER_SWEEP_CAPTURE_PANE_FN=mock_capture_pane
export BRIDGE_PICKER_SWEEP_SEND_ENTER_FN=mock_send_enter
export BRIDGE_PICKER_SWEEP_SEND_OPTION_FN=mock_send_option
export BRIDGE_PICKER_SWEEP_CREATE_TASK_FN=mock_create_task
export BRIDGE_PICKER_SWEEP_ROTATE_CLAUDE_TOKEN_FN=mock_rotate_claude_token

# Pin per-sweep log so we can see which sweep won the lock and which
# deferred.
export BRIDGE_PICKER_SWEEP_LOG="$1"

# Force enable; the smoke's BRIDGE_HOME has no host-profile.json so
# host_profile is unknown — be explicit.
export BRIDGE_PICKER_SWEEP_ENABLED=1
export BRIDGE_PICKER_SWEEP_NOTIFY=""  # don't try to enqueue a real task

exec bash "$PICKER_SWEEP"
WRAP_EOF
chmod +x "$SWEEP_WRAPPER"

# ---------------------------------------------------------------------------
# Fixture: one tmux session "stuck-agent" sitting on a rate-limit picker.
# Both sweeps will see this session and try to rotate.
# ---------------------------------------------------------------------------

printf '%s\n' "stuck-agent" > "$SESSIONS_FILE"
cat >"$PANE_FILE" <<'PANE'
Some prior output
❯ 1. Stop and wait for limit to reset
  2. Switch to extra usage
  3. Switch to Team plan
Enter to confirm · Esc to cancel
PANE

export FIXTURE_DIR PICKER_SWEEP SESSIONS_FILE ROTATE_COUNT_FILE ROTATE_LOG ROTATE_SLEEP_SECS

# Disable host_profile dev-skip explicitly (BRIDGE_HOME has no
# host-profile.json; bridge_host_profile_is_dev returns false, but
# being explicit guards against future helper changes).
export BRIDGE_PICKER_SWEEP_ENABLED=1

reset_round() {
    : > "$ROTATE_COUNT_FILE"
    printf '0\n' > "$ROTATE_COUNT_FILE"
    : > "$ROTATE_LOG"
    : > "$SWEEP_LOG_A"
    : > "$SWEEP_LOG_B"
    # Wipe the cooldown state + rotation lock state from any prior
    # round so each round is a clean "rotation is due" starting point.
    rm -rf "$BRIDGE_HOME/state/picker-sweep" 2>/dev/null || true
    mkdir -p "$BRIDGE_HOME/state/picker-sweep"
}

run_round() {
    local round_num="$1"
    reset_round

    smoke_log "round $round_num — launching two concurrent picker-sweep processes"

    local pid_a pid_b rc_a rc_b
    "$SWEEP_WRAPPER" "$SWEEP_LOG_A" &
    pid_a=$!
    "$SWEEP_WRAPPER" "$SWEEP_LOG_B" &
    pid_b=$!

    # Use set +e around `wait` so we can capture each rc independently
    # without bailing the smoke (a non-zero sweep exit IS a failure but
    # the assertion shape should surface what specifically happened).
    set +e
    wait "$pid_a"; rc_a=$?
    wait "$pid_b"; rc_b=$?
    set -e

    smoke_assert_eq "0" "$rc_a" "round $round_num sweep-a exited cleanly"
    smoke_assert_eq "0" "$rc_b" "round $round_num sweep-b exited cleanly"

    local count
    count="$(cat "$ROTATE_COUNT_FILE" 2>/dev/null || printf '0')"
    smoke_assert_eq "1" "$count" "round $round_num exactly one rotate call (rotation lock serialised the two sweeps)"

    # At least one sweep should have logged a defer message. If neither
    # did, the two sweeps happened to land non-overlapping in time and
    # the lock wasn't even contested — that's a valid no-op outcome
    # (test still proves no double-rotate), so we make this assertion
    # soft: count it across the run and warn only if NONE of ROUNDS
    # rounds saw a defer. The hard assertion is the rotate count.
    if grep -q "deferred (another sweep holds the rotation lock)" "$SWEEP_LOG_A" "$SWEEP_LOG_B" 2>/dev/null; then
        deferred_round_count=$(( deferred_round_count + 1 ))
    fi
}

deferred_round_count=0
for round in $(seq 1 "$ROUNDS"); do
    run_round "$round"
done

if (( deferred_round_count == 0 )); then
    smoke_log "warn: no round observed a lock-defer log — the smoke proved no double-rotate but did not exercise the contested-lock path. Consider raising BRIDGE_PICKER_SWEEP_CONCURRENT_SMOKE_SLEEP."
fi

smoke_log "all checks passed ($ROUNDS rounds, deferred in $deferred_round_count round(s))"
