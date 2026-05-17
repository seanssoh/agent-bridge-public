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

# #948 — mock for the explicit "send N + Enter" path. Records the agent and
# option number so smoke assertions can verify the correct option was sent.
mock_send_option() {
    local target="$1" option_num="$2"
    printf '%s:option=%s\n' "$target" "$option_num" >> "$SEND_OPTION_LOG"
}

mock_create_task() {
    local title="$1" body="$2" recipient="$3"
    printf 'recipient=%s\ntitle=%s\nbody=%s\n---\n' \
        "$recipient" "$title" "$body" >> "$TASK_LOG"
}

export -f mock_list_sessions mock_capture_pane mock_send_enter mock_send_option mock_create_task
MOCK_EOF
# shellcheck source=/dev/null
source "$MOCK_LIB"

# Wire seams.
export BRIDGE_PICKER_SWEEP_LIST_SESSIONS_FN=mock_list_sessions
export BRIDGE_PICKER_SWEEP_CAPTURE_PANE_FN=mock_capture_pane
export BRIDGE_PICKER_SWEEP_SEND_ENTER_FN=mock_send_enter
export BRIDGE_PICKER_SWEEP_SEND_OPTION_FN=mock_send_option
export BRIDGE_PICKER_SWEEP_CREATE_TASK_FN=mock_create_task

# Pin the log file so the smoke can inspect it.
export BRIDGE_PICKER_SWEEP_LOG="$FIXTURE_DIR/picker-sweep.log"
SEND_OPTION_LOG="$FIXTURE_DIR/sent-options.log"
export FIXTURE_DIR SEND_LOG SEND_OPTION_LOG TASK_LOG

reset_fixture() {
    rm -f "$FIXTURE_DIR/sessions" "$FIXTURE_DIR"/pane-* "$SEND_LOG" "$SEND_OPTION_LOG" "$TASK_LOG" "$BRIDGE_PICKER_SWEEP_LOG"
    : >"$FIXTURE_DIR/sessions"
    : >"$SEND_LOG"
    : >"$SEND_OPTION_LOG"
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
smoke_assert_contains "$(cat "$TASK_LOG")" "stuck-agent:picker option line + tail (sent Enter)" "4 task body lists agent + action"

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


# ---------------------------------------------------------------------------
# Test 7 — Claude Code development-channels warning (post-v0.14.1 addition).
# ---------------------------------------------------------------------------

smoke_log "7. dev-channels warning → unstick"
reset_fixture
printf '%s\n' "dev-channels-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-dev-channels-agent" <<'PANE'
  WARNING: Loading development channels

  --dangerously-load-development-channels is for local channel development only.

  Channels: plugin:teams@agent-bridge, plugin:ms365@agent-bridge

  ❯ 1. I am using this for local development
    2. Exit

  Enter to confirm · Esc to cancel
PANE

export BRIDGE_PICKER_SWEEP_NOTIFY="admin"
run_sweep
smoke_assert_eq "1" "$(count_lines "$SEND_LOG")" "7 one send (dev-channels warning auto-accepted)"
smoke_assert_eq "1" "$(grep -c "^---$" "$TASK_LOG" || true)" "7 one task (notify admin)"

# ---------------------------------------------------------------------------
# Test 8 — Codex CLI "Press enter to continue" cwd-confirm prompt.
# ---------------------------------------------------------------------------

smoke_log "8. codex cwd-confirm → unstick"
reset_fixture
printf '%s\n' "codex-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-codex-agent" <<'PANE'
  Working directory: /home/sean/agent-bridge-public
  Press enter to continue
PANE

run_sweep
smoke_assert_eq "1" "$(count_lines "$SEND_LOG")" "8 one send (codex cwd-confirm auto-accepted)"
smoke_assert_eq "1" "$(grep -c "^---$" "$TASK_LOG" || true)" "8 one task (notify admin)"

# ---------------------------------------------------------------------------
# Test 9 — codex confirm regex must NOT trip on free-prose mention.
# ---------------------------------------------------------------------------

smoke_log "9. codex confirm — false-positive defence (free-prose)"
reset_fixture
printf '%s\n' "doc-agent2" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-doc-agent2" <<'PANE'
> When codex shows "Press enter to continue" the operator types Enter.
> See codex docs for the cwd-confirm flow.
PANE

run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "9 no send (codex confirm in '>' quote)"

# ---------------------------------------------------------------------------
# Test 10 — Bypass Permissions warning (#948). Default cursor is on
# "No, exit" so bare Enter would EXIT Claude. Must send option 2 explicitly.
# ---------------------------------------------------------------------------

smoke_log "10. bypass-permissions warning → send option 2"
reset_fixture
printf '%s\n' "bypass-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-bypass-agent" <<'PANE'
  WARNING: Claude Code running in Bypass Permissions mode

  In Bypass Permissions mode, Claude Code will not ask for your approval
  before running potentially dangerous commands.

  ❯ 1. No, exit
    2. Yes, I accept

  Enter to confirm · Esc to cancel
PANE

export BRIDGE_PICKER_SWEEP_NOTIFY="admin"
run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "10 no bare-Enter send (would EXIT Claude)"
smoke_assert_eq "1" "$(count_lines "$SEND_OPTION_LOG")" "10 one option send"
smoke_assert_contains "$(cat "$SEND_OPTION_LOG")" "bypass-agent:option=2" "10 send option=2 (Yes I accept)"
smoke_assert_contains "$(cat "$TASK_LOG")" "bypass-agent:bypass-permissions warning (sent option 2)" "10 task body records explicit option send"

# ---------------------------------------------------------------------------
# Test 11 — Auto mode warning (#948). 3-option picker; send option 1 so the
# mode becomes the user default and subsequent claude restarts skip the prompt.
# ---------------------------------------------------------------------------

smoke_log "11. auto-mode warning → send option 1"
reset_fixture
printf '%s\n' "auto-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-auto-agent" <<'PANE'
  WARNING: Auto mode allows Claude to run commands automatically.

  ❯ 1. Yes, and make it my default mode
    2. Yes, enable auto mode
    3. No, exit

  Enter to confirm · Esc to cancel
PANE

run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "11 no bare-Enter send"
smoke_assert_eq "1" "$(count_lines "$SEND_OPTION_LOG")" "11 one option send"
smoke_assert_contains "$(cat "$SEND_OPTION_LOG")" "auto-agent:option=1" "11 send option=1 (make default)"
smoke_assert_contains "$(cat "$TASK_LOG")" "auto-agent:auto-mode warning (sent option 1)" "11 task body records explicit option send"

# ---------------------------------------------------------------------------
# Test 12 — Bypass/auto patterns must NOT fire on free-prose mention.
# Same false-positive defence as Test 3/9 but for the new regexes.
# ---------------------------------------------------------------------------

smoke_log "12. bypass/auto patterns — false-positive defence (free-prose)"
reset_fixture
printf '%s\n' "doc-agent3" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-doc-agent3" <<'PANE'
> The picker reads:
>   ❯ 1. No, exit
>     2. Yes, I accept
> When the operator selects "2. Yes, I accept" the warning is acked.
> Auto mode picker similar: 1. Yes, and make it my default mode / 2. Yes, enable auto mode / 3. No, exit
PANE

run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "12 no bare-Enter send (free-prose)"
smoke_assert_eq "0" "$(count_lines "$SEND_OPTION_LOG")" "12 no option send (free-prose)"

# ---------------------------------------------------------------------------
# Test 13 — Generic exit-option menu (#948 r3 hardening from codex PR #949
# r2 review). A different Claude warning whose menu also lists "No, exit"
# must NOT trigger the bypass-permissions / auto-mode send paths — those
# now key off the distinctive accept-option line, not the generic exit.
# ---------------------------------------------------------------------------

smoke_log "13. generic exit-option menu — must NOT trigger bypass/auto send (r3 hardening)"
reset_fixture
printf '%s\n' "generic-exit-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-generic-exit-agent" <<'PANE'
  WARNING: An unrelated Claude warning that happens to share menu shape.

  ❯ 1. No, exit
    2. Do something completely unrelated to permissions
    3. Try another path

  Enter to confirm · Esc to cancel
PANE

run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "13 no bare-Enter send"
smoke_assert_eq "0" "$(count_lines "$SEND_OPTION_LOG")" "13 no option send (generic exit ≠ bypass/auto accept)"

# ---------------------------------------------------------------------------
# Test 14 — r4 hardening (codex PR #949 r3): capture contains a STALE
# bypass-warning accept line above an ACTIVE auto-mode picker. The bypass
# branch would otherwise win and send option 2 into the auto-mode menu
# (= "Yes, enable auto mode just this once"), and the ack would not
# persist across restarts. The fix scopes detection to the last picker
# block (after the most recent tail), so only the active picker's accept
# line matters.
# ---------------------------------------------------------------------------

smoke_log "14. stale bypass + active auto-mode in same capture → send auto's option 1 (r4)"
reset_fixture
printf '%s\n' "combo-agent" > "$FIXTURE_DIR/sessions"
cat >"$FIXTURE_DIR/pane-combo-agent" <<'PANE'
  WARNING: Claude Code running in Bypass Permissions mode

  ❯ 1. No, exit
    2. Yes, I accept

  Enter to confirm · Esc to cancel
  WARNING: Auto mode allows Claude to run commands automatically.

  ❯ 1. Yes, and make it my default mode
    2. Yes, enable auto mode
    3. No, exit

  Enter to confirm · Esc to cancel
PANE

run_sweep
smoke_assert_eq "0" "$(count_lines "$SEND_LOG")" "14 no bare-Enter send"
smoke_assert_eq "1" "$(count_lines "$SEND_OPTION_LOG")" "14 one option send (active picker only)"
smoke_assert_contains "$(cat "$SEND_OPTION_LOG")" "combo-agent:option=1" "14 send option=1 (auto-mode active, NOT stale bypass option 2)"

smoke_log "all checks passed"
