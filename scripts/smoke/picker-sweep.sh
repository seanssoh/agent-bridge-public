#!/usr/bin/env bash
# scripts/smoke/picker-sweep.sh — fixture smoke for the picker-sweep utility.
#
# Validates picker-sweep.sh in isolation:
#   1. Explicit-opt-out gate: BRIDGE_PICKER_SWEEP_ENABLED=0 → no-op exit 0
#      (Default has flipped to enabled on host_profile=server since PR #813;
#      this smoke runs picker-sweep.sh outside a real BRIDGE_HOME, so the
#      host_profile-aware default helper short-circuits — the smoke continues
#      to drive the env-override path explicitly.)
#   2. Self-skip: agent matching BRIDGE_PICKER_SWEEP_SELF is skipped
#   3. False-positive defence: a session containing picker text in
#      free-prose context (PR body, doc, log) does NOT trigger send-keys
#   4. Picker option line match: real picker pane → send Enter, summary task
#   5. Tail-only (no option line) → rejected (defends against generic tool
#      confirmation prompts that codex r1 flagged as a false-positive vector)
#   5b. Picker option line + tail combined → send Enter (canonical positive)
#   6. Notify-empty path: BRIDGE_PICKER_SWEEP_NOTIFY="" → send Enter, no task
#
# Test seams: this smoke replaces tmux + agent-bridge calls with mock shell
# functions exported through BRIDGE_PICKER_SWEEP_*_FN env vars. The mocks
# read from a $FIXTURE_DIR file structure so the script never touches a real
# tmux server or a real queue.

set -euo pipefail

SMOKE_NAME="picker-sweep"
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

# Captured side effects from the mocks (one line per call).
SEND_LOG="$FIXTURE_DIR/sent-keys.log"
TASK_LOG="$FIXTURE_DIR/created-tasks.log"

# ---------------------------------------------------------------------------
# Mock harness — written to a file the test can sourceable as functions.
#
# The mocks read the per-test fixture state from $FIXTURE_DIR:
#   $FIXTURE_DIR/sessions       — newline-list of session names
#   $FIXTURE_DIR/pane-<name>    — capture-pane content for that name
# and append events to $SEND_LOG and $TASK_LOG.
# ---------------------------------------------------------------------------

MOCK_LIB="$FIXTURE_DIR/mock-lib.sh"
cat >"$MOCK_LIB" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock test seams for picker-sweep smoke. Sourced by the smoke runner shell
# *before* invoking picker-sweep.sh, then exposed through env-var function
# names that picker-sweep.sh resolves at runtime.

mock_list_sessions() {
    if [[ -f "$FIXTURE_DIR/sessions" ]]; then
        cat "$FIXTURE_DIR/sessions"
    fi
}

mock_capture_pane() {
    local target="$1"
    local f="$FIXTURE_DIR/pane-$target"
    if [[ -f "$f" ]]; then
        cat "$f"
    fi
}

mock_send_enter() {
    local target="$1"
    printf '%s\n' "$target" >> "$SEND_LOG"
}

mock_create_task() {
    local title="$1" body="$2" recipient="$3"
    printf 'recipient=%s\ntitle=%s\nbody=%s\n---\n' \
        "$recipient" "$title" "$body" >> "$TASK_LOG"
}

export -f mock_list_sessions mock_capture_pane mock_send_enter mock_create_task
MOCK_EOF
# shellcheck source=/dev/null
source "$MOCK_LIB"

# Wire seams.
export BRIDGE_PICKER_SWEEP_LIST_SESSIONS_FN=mock_list_sessions
export BRIDGE_PICKER_SWEEP_CAPTURE_PANE_FN=mock_capture_pane
export BRIDGE_PICKER_SWEEP_SEND_ENTER_FN=mock_send_enter
export BRIDGE_PICKER_SWEEP_CREATE_TASK_FN=mock_create_task

# Pin the log file so the smoke can inspect it.
export BRIDGE_PICKER_SWEEP_LOG="$FIXTURE_DIR/picker-sweep.log"
export FIXTURE_DIR SEND_LOG TASK_LOG

reset_fixture() {
    rm -f "$FIXTURE_DIR/sessions" "$FIXTURE_DIR"/pane-* "$SEND_LOG" "$TASK_LOG" "$BRIDGE_PICKER_SWEEP_LOG"
    : >"$FIXTURE_DIR/sessions"
    : >"$SEND_LOG"
    : >"$TASK_LOG"
}

run_sweep() {
    bash "$PICKER_SWEEP"
}

count_lines() {
    local f="$1"
    if [[ -f "$f" ]]; then
        wc -l <"$f" | tr -d '[:space:]'
    else
        printf '0'
    fi
}

# ---------------------------------------------------------------------------
# Test 1 — Explicit-opt-out gate.
#
# Default flipped to enabled on host_profile=server in PR #813. The smoke
# fixture has no BRIDGE_HOME (no state/install/host-profile.json), so
# `bridge_host_profile_is_dev` returns false (fail-closed) and the host_profile
# branch in picker-sweep.sh does not fire. The remaining gate is the
# explicit operator opt-out: BRIDGE_PICKER_SWEEP_ENABLED=0.
# ---------------------------------------------------------------------------

smoke_log "1. explicit-opt-out gate"
reset_fixture
printf '%s\n' "agent-a" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-agent-a" <<'PANE'
❯ 1. Stop and wait for limit to reset
  2. Switch to extra usage
  3. Switch to Team plan
Enter to confirm · Esc to cancel
PANE

export BRIDGE_PICKER_SWEEP_ENABLED=0
run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "1 no send (gate closed)"
smoke_assert_eq "0" "$(count_lines "$TASK_LOG")" "1 no task (gate closed)"
smoke_assert_contains "$(cat "$BRIDGE_PICKER_SWEEP_LOG")" "explicit opt-out" "1 gate logged"

# Enable for the remaining tests.
export BRIDGE_PICKER_SWEEP_ENABLED=1

# ---------------------------------------------------------------------------
# Test 2 — Self-skip.
# ---------------------------------------------------------------------------

smoke_log "2. self-skip"
reset_fixture
printf '%s\n%s\n' "self-agent" "other-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-self-agent" <<'PANE'
❯ 1. Stop and wait for limit to reset
  2. Switch to extra usage
Enter to confirm · Esc to cancel
PANE
cat >"$FIXTURE_DIR/pane-other-agent" <<'PANE'
nothing interesting here, just a regular shell prompt
PANE

export BRIDGE_PICKER_SWEEP_SELF="self-agent"
export BRIDGE_PICKER_SWEEP_NOTIFY="admin"
run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "2 no send (self-agent skipped, other clean)"
smoke_assert_eq "0" "$(count_lines "$TASK_LOG")" "2 no task"

# ---------------------------------------------------------------------------
# Test 3 — False-positive defence.
# ---------------------------------------------------------------------------

smoke_log "3. false-positive defence (free-prose picker text)"
reset_fixture
printf '%s\n' "doc-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-doc-agent" <<'PANE'
> The picker pattern looks like this:
>   ❯ 1. Stop and wait for limit to reset
>   2. Switch to extra usage
> When users press Enter to confirm · Esc to cancel, the menu collapses.
> See PR #295 for the regex hardening.
PANE

# Wrapped in '>' quote markers so neither the option-line regex (line-anchored)
# nor the tail regex (line-anchored to its exact form) should match.
run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "3 no send (free-prose picker text)"
smoke_assert_eq "0" "$(count_lines "$TASK_LOG")" "3 no task"

# ---------------------------------------------------------------------------
# Test 4 — Picker option line match.
# ---------------------------------------------------------------------------

smoke_log "4. picker option line → unstick + task"
reset_fixture
printf '%s\n' "stuck-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-stuck-agent" <<'PANE'
Some prior output
❯ 1. Stop and wait for limit to reset
  2. Switch to extra usage
  3. Switch to Team plan
Enter to confirm · Esc to cancel
PANE

run_sweep
smoke_assert_eq "1" "$(count_lines "$SEND_LOG")" "4 one send"
smoke_assert_contains "$(cat "$SEND_LOG")" "stuck-agent" "4 send target"
smoke_assert_eq "1" "$(grep -c "^---$" "$TASK_LOG" || true)" "4 one task"
smoke_assert_contains "$(cat "$TASK_LOG")" "recipient=admin" "4 task recipient"
smoke_assert_contains "$(cat "$TASK_LOG")" "1 agent(s) auto-unstuck" "4 task title"
smoke_assert_contains "$(cat "$TASK_LOG")" "stuck-agent:picker option line" "4 task body lists agent"

# ---------------------------------------------------------------------------
# Test 5 — Tail-only (no option line) must be REJECTED.
#
# Codex r1 review caught that the previous `elif tail` branch matched any
# pane with the "Enter to confirm · Esc to cancel" tail — including generic
# tool-confirmation prompts, PR bodies, docs, and logs quoting Claude Code's
# confirm prompt. The fix requires _PICKER_OPTION_LINE_RE to match; tail
# alone is no longer sufficient. This test pins that defence.
# ---------------------------------------------------------------------------

smoke_log "5. tail-only (no option line) → rejected (false-positive defence)"
reset_fixture
printf '%s\n' "tail-only-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-tail-only-agent" <<'PANE'
A tool ran with this prompt:
Enter to confirm · Esc to cancel
PANE

run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "5 no send (tail-only must not trigger)"
smoke_assert_eq "0" "$(grep -c "^---$" "$TASK_LOG" || true)" "5 no task (tail-only must not trigger)"

# ---------------------------------------------------------------------------
# Test 5b — Picker option line + tail combined → unstick (canonical positive).
#
# Mirrors Test 4 but asserts the "option line + tail" matched_pattern path
# explicitly, so future maintainers can see both detection branches exercised.
# ---------------------------------------------------------------------------

smoke_log "5b. picker option line + tail → unstick (positive)"
reset_fixture
printf '%s\n' "full-picker-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-full-picker-agent" <<'PANE'
❯ 1. Resume from summary (recommended)
  2. Resume full session as-is
Enter to confirm · Esc to cancel
PANE

run_sweep
smoke_assert_eq "1" "$(count_lines "$SEND_LOG")" "5b one send (option+tail match)"
smoke_assert_contains "$(cat "$SEND_LOG")" "full-picker-agent" "5b send target"

# ---------------------------------------------------------------------------
# Test 6 — Notify-empty path.
# ---------------------------------------------------------------------------

smoke_log "6. notify empty → unstick, no task"
reset_fixture
printf '%s\n' "notify-empty-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-notify-empty-agent" <<'PANE'
❯ 1. Resume from summary (recommended)
  2. Resume full session as-is
Enter to confirm · Esc to cancel
PANE

export BRIDGE_PICKER_SWEEP_NOTIFY=""
run_sweep
smoke_assert_eq "1" "$(count_lines "$SEND_LOG")" "6 one send"
smoke_assert_eq "0" "$(count_lines "$TASK_LOG")" "6 no task (notify empty)"
smoke_assert_contains "$(cat "$BRIDGE_PICKER_SWEEP_LOG")" "BRIDGE_PICKER_SWEEP_NOTIFY unset" "6 notify-skip logged"

smoke_log "all checks passed"
