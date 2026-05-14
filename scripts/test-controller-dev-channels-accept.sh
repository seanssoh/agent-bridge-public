#!/usr/bin/env bash
# Regression coverage for issue #825 — controller-side dev-channels
# auto-accept watcher silent failure.
#
# Background: bridge-start.sh::bridge_start_schedule_dev_channels_accept
# previously waited for `bridge_tmux_wait_for_claude_foreground` to succeed
# before dispatching the Enter that clears the
# `--dangerously-load-development-channels` picker. The foreground gate is
# basename-matched (`claude|claude-*|claude.*`) plus a process-tree walk;
# on live v0.11.0+ installs the gate was observed to false-negative even
# after the picker was on screen, wedging the watcher indefinitely. The
# fix (this commit) makes pane-content-text the PRIMARY trigger: when the
# dev-channels picker text is visible in the pane, the watcher dispatches
# Enter regardless of foreground basename.
#
# Cases:
#   R1 Positive control: exact-basename `claude` stub prints the picker
#      text + waits on stdin; watcher fires Enter via the picker-text
#      trigger; ack file records `<enter>`.
#   R2 Negative control (the bug): foreground process is NOT named
#      `claude` and the process tree has no claude descendant, but the
#      pane contains the picker text. Pre-fix would time out without
#      sending Enter; post-fix the picker-text trigger fires.
#   R3 Neighbor guard: the picker-sweep allow-list
#      (scripts/picker-sweep.sh:137-138) does NOT include the dev-channels
#      picker text, so picker-sweep does not grab a dev-channels pane.
#   R4 Timeout-still-works: pane has neither picker text nor claude
#      foreground; bridge_tmux_pane_has_dev_channels_picker returns 1
#      forever, the legacy foreground gate also returns 1, and the
#      watcher times out at foreground_timeout instead of looping
#      forever.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP_ROOT="$(mktemp -d -t agb-825-controller-accept.XXXXXX)"
SMOKE_SESSIONS=()
# shellcheck disable=SC2329 # invoked via `trap cleanup EXIT`
cleanup() {
  local s
  for s in "${SMOKE_SESSIONS[@]:-}"; do
    [[ -n "$s" ]] && tmux kill-session -t "=$s" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

if ! command -v tmux >/dev/null 2>&1; then
  printf 'tmux not available — skipping issue #825 regression suite\n' >&2
  exit 0
fi

BASH_BIN="${BRIDGE_BASH_BIN:-bash}"

# v0.8.0 hard-cut: bridge-lib.sh refuses to source on an installation that
# is not isolation-v2. The regression test owns a throwaway BRIDGE_HOME, so
# write a minimal valid v2 marker (layout-marker.sh) into it so the
# resolver enters the marker branch and lets sourcing proceed. This is the
# same shape `agent-bridge upgrade --apply` writes after migration.
#
# Scrub inherited BRIDGE_* env first so the parent shell's live-runtime
# values (BRIDGE_LAYOUT=legacy, BRIDGE_HOME=$HOME/.agent-bridge, etc.) do
# not bleed into the isolated test home. The resolver runs the env
# validator BEFORE the marker load, so a stale BRIDGE_LAYOUT=legacy
# in the parent env would hard-die before the marker is even read.
unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT BRIDGE_LAYOUT_SOURCE
unset BRIDGE_LAYOUT_RESOLVER_BYPASS BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID
TEST_BRIDGE_HOME="$TMP_ROOT/bridge-home"
mkdir -p "$TEST_BRIDGE_HOME/state" "$TEST_BRIDGE_HOME/data"
MARKER_PATH="$TEST_BRIDGE_HOME/state/layout-marker.sh"
cat >"$MARKER_PATH" <<MARKER
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT=$TEST_BRIDGE_HOME/data
MARKER
chmod 0644 "$MARKER_PATH"
export BRIDGE_HOME="$TEST_BRIDGE_HOME"
export BRIDGE_STATE_DIR="$TEST_BRIDGE_HOME/state"
export BRIDGE_LAYOUT_MARKER_DIR="$TEST_BRIDGE_HOME/state"

# ---------------------------------------------------------------------------
# Helper: wait until the pane of a tmux session contains a given substring.
# Returns 0 on match, 1 on timeout.
# ---------------------------------------------------------------------------
wait_for_pane_text() {
  local session="$1"
  local needle="$2"
  local attempts="${3:-50}"
  local sleep_secs="${4:-0.1}"
  local i
  for ((i = 0; i < attempts; i++)); do
    if tmux capture-pane -p -t "=${session}:" 2>/dev/null \
        | grep -Fq "$needle"; then
      return 0
    fi
    sleep "$sleep_secs"
  done
  return 1
}

# ---------------------------------------------------------------------------
# Helper: run the controller watcher subshell body in-process so we can
# assert on its outcome. The real bridge_start_schedule_dev_channels_accept
# launches the watcher in the background; here we run it foreground with
# tightened timeouts so the test reports pass/fail synchronously.
#
# Returns:
#   stdout: log lines from the watcher
#   exit code: forwarded from the watcher subshell body
# ---------------------------------------------------------------------------
run_controller_watcher_inline() {
  local session="$1"
  local agent="$2"
  local accept_timeout="${3:-3}"
  local foreground_timeout="${4:-3}"
  local poll_seconds="${5:-0.1}"

  BRIDGE_START_DEV_CHANNELS_PICKER_POLL_SECONDS="$poll_seconds" \
  BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_WAIT_SECONDS=2 \
  BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_POLL_SECONDS=0.1 \
  BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_MAX_CHECKS=20 \
  BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_SETTLE_SECONDS=0.05 \
    "$BASH_BIN" -lc '
      set -euo pipefail
      script_dir="$1"
      session="$2"
      agent="$3"
      accept_timeout="$4"
      foreground_timeout="$5"
      source "$script_dir/bridge-lib.sh"
      if ! bridge_tmux_session_exists "$session"; then
        printf "session-gone\n" >&2
        exit 0
      fi
      picker_seen=0
      foreground_ready=0
      poll_seconds="${BRIDGE_START_DEV_CHANNELS_PICKER_POLL_SECONDS:-2}"
      [[ "$poll_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || poll_seconds=2
      start_ts="$(date +%s)"
      while :; do
        if ! bridge_tmux_session_exists "$session"; then
          printf "session-ended-mid-wait\n" >&2
          exit 0
        fi
        if bridge_tmux_pane_has_dev_channels_picker "$session"; then
          picker_seen=1
          break
        fi
        if bridge_tmux_pane_foreground_is_claude "$session"; then
          foreground_ready=1
          break
        fi
        elapsed=$(( $(date +%s) - start_ts ))
        if (( elapsed >= foreground_timeout )); then
          printf "timeout-waiting-for-picker-or-foreground\n" >&2
          exit 2
        fi
        sleep "$poll_seconds"
      done
      if (( picker_seen == 1 )); then
        export BRIDGE_TMUX_DEV_CHANNELS_REQUIRE_CLAUDE_FOREGROUND=0
        printf "trigger=picker\n"
      else
        printf "trigger=foreground\n"
      fi
      if bridge_tmux_wait_for_prompt "$session" claude "$accept_timeout" 1; then
        printf "dispatch=ok\n"
        exit 0
      else
        printf "dispatch=fail\n" >&2
        exit 3
      fi
    ' -- "$ROOT_DIR" "$session" "$agent" "$accept_timeout" "$foreground_timeout"
}

# ---------------------------------------------------------------------------
# R1: positive control — exact-basename `claude` foreground stub.
# ---------------------------------------------------------------------------
step "R1: exact-basename claude stub triggers dev-channels Enter"
R1_BIN_DIR="$TMP_ROOT/r1-bin"
mkdir -p "$R1_BIN_DIR"
R1_SESSION="agb-825-r1-$$"
R1_ACK="$TMP_ROOT/r1-ack.txt"
R1_PAYLOAD="$TMP_ROOT/r1-payload.sh"
R1_DRIVER="$TMP_ROOT/r1-driver.sh"
# A "claude" symlink to bash so `ps -o comm=` on the pane PID reports
# basename `claude` (matches bridge_tmux_command_name_is_claude).
ln -sf "$(command -v bash)" "$R1_BIN_DIR/claude"
cat >"$R1_PAYLOAD" <<R1PAY
IFS= read -r line
printf '%s\n' "\${line:-<enter>}" >"$R1_ACK"
# Print a Claude-style ready prompt so bridge_tmux_session_has_prompt
# succeeds and bridge_tmux_wait_for_prompt returns 0 after the picker
# Enter is sent. The picker text up the buffer no longer matters; only
# the most recent 20 lines are scanned.
printf '\n❯ \n'
sleep 2
R1PAY
chmod +x "$R1_PAYLOAD"
cat >"$R1_DRIVER" <<R1DRV
#!/usr/bin/env bash
printf 'WARNING: Loading development channels\n'
printf 'I am using this for local development\n'
printf 'Enter to confirm · Esc to cancel\n'
exec "$R1_BIN_DIR/claude" "$R1_PAYLOAD"
R1DRV
chmod +x "$R1_DRIVER"
tmux new-session -d -s "$R1_SESSION" "$R1_DRIVER"
SMOKE_SESSIONS+=("$R1_SESSION")
wait_for_pane_text "$R1_SESSION" "WARNING: Loading development channels" 50 0.1 \
  || { err "R1 driver did not render dev-channels banner"; }
if [[ "$FAIL" -eq 0 ]]; then
  if run_controller_watcher_inline "$R1_SESSION" "r1-agent" 3 3 0.1 >/dev/null 2>&1; then
    for _ in {1..30}; do
      [[ -s "$R1_ACK" ]] && break
      sleep 0.1
    done
    if [[ -s "$R1_ACK" ]] && grep -q "<enter>" "$R1_ACK"; then
      ok
    else
      err "R1 expected Enter ack but file empty/wrong: $(cat "$R1_ACK" 2>/dev/null || echo MISSING)"
    fi
  else
    err "R1 watcher rc != 0"
  fi
fi

# ---------------------------------------------------------------------------
# R2: negative control — non-claude foreground basename + no claude
# descendant in the process tree + picker text visible. This is the bug
# shape from issue #825. Pre-fix watcher would time out at the foreground
# gate; post-fix watcher must dispatch via the picker-text trigger.
# ---------------------------------------------------------------------------
step "R2: non-claude foreground + picker text triggers dispatch (the bug)"
R2_BIN_DIR="$TMP_ROOT/r2-bin"
mkdir -p "$R2_BIN_DIR"
R2_SESSION="agb-825-r2-$$"
R2_ACK="$TMP_ROOT/r2-ack.txt"
R2_PAYLOAD="$TMP_ROOT/r2-payload.sh"
R2_DRIVER="$TMP_ROOT/r2-driver.sh"
# A "node" symlink to bash so `ps -o comm=` of the pane PID reports
# basename `node` (does NOT match bridge_tmux_command_name_is_claude).
# This stub has no claude descendant in its process tree — it is the
# exact pre-fix wedge shape: foreground != claude, no claude under it,
# but picker text on screen.
ln -sf "$(command -v bash)" "$R2_BIN_DIR/node"
cat >"$R2_PAYLOAD" <<R2PAY
IFS= read -r line
printf '%s\n' "\${line:-<enter>}" >"$R2_ACK"
# Same prompt-render trick as R1 so wait_for_prompt returns 0 after the
# picker Enter is sent.
printf '\n❯ \n'
sleep 2
R2PAY
chmod +x "$R2_PAYLOAD"
cat >"$R2_DRIVER" <<R2DRV
#!/usr/bin/env bash
printf 'WARNING: Loading development channels\n'
printf 'I am using this for local development\n'
printf 'Enter to confirm · Esc to cancel\n'
exec "$R2_BIN_DIR/node" "$R2_PAYLOAD"
R2DRV
chmod +x "$R2_DRIVER"
tmux new-session -d -s "$R2_SESSION" "$R2_DRIVER"
SMOKE_SESSIONS+=("$R2_SESSION")
wait_for_pane_text "$R2_SESSION" "I am using this for local development" 50 0.1 \
  || { err "R2 driver did not render dev-channels banner"; }
if [[ "$FAIL" -eq 0 || ("$LAST_DESC" == "R2"* && "$R2_ACK" != "" ) ]]; then
  # Verify the pre-condition: foreground gate alone DOES fail here. If
  # this assertion fails the test is invalid (the stub somehow inherited
  # a claude descendant via PATH).
  if "$BASH_BIN" -c '
    source "'"$ROOT_DIR"'/bridge-lib.sh"
    bridge_tmux_pane_foreground_is_claude "'"$R2_SESSION"'"
  ' >/dev/null 2>&1; then
    err "R2 invariant failed: foreground gate succeeded on the node-stub pane (no claude descendant expected)"
  else
    R2_LOG="$TMP_ROOT/r2-watcher.log"
    if run_controller_watcher_inline "$R2_SESSION" "r2-agent" 3 3 0.1 >"$R2_LOG" 2>&1; then
      for _ in {1..30}; do
        [[ -s "$R2_ACK" ]] && break
        sleep 0.1
      done
      if [[ -s "$R2_ACK" ]] && grep -q "<enter>" "$R2_ACK" \
        && grep -q '^trigger=picker$' "$R2_LOG" \
        && grep -q '^dispatch=ok$' "$R2_LOG"; then
        ok
      else
        err "R2 expected picker-trigger + dispatch=ok, got log: $(cat "$R2_LOG"); ack: $(cat "$R2_ACK" 2>/dev/null || echo MISSING)"
      fi
    else
      err "R2 watcher rc != 0 (pre-fix would behave this way); log: $(cat "$R2_LOG" 2>/dev/null || true)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# R3: neighbor guard — the picker-sweep allow-list does NOT include the
# dev-channels picker text. We exercise picker-sweep against a dev-channels
# pane and assert the sweep does not send Enter into it.
# ---------------------------------------------------------------------------
step "R3: picker-sweep does NOT match dev-channels picker text"
R3_DIR="$TMP_ROOT/r3"
mkdir -p "$R3_DIR/lib" "$R3_DIR/state/install" "$R3_DIR/scripts"
cp "$ROOT_DIR/lib/bridge-host-profile.sh" "$R3_DIR/lib/"
cp "$ROOT_DIR/scripts/picker-sweep.sh" "$R3_DIR/scripts/"
printf '{"profile":"server"}\n' > "$R3_DIR/state/install/host-profile.json"

R3_SEND_RECORD="$R3_DIR/picker-sweep-sends.log"
R3_TASKS_RECORD="$R3_DIR/picker-sweep-tasks.log"
: > "$R3_SEND_RECORD" "$R3_TASKS_RECORD"

# Test seam shims: list a single fake session that capture-pane will
# return the dev-channels picker text for. If picker-sweep wrongly grabs
# this pane it will call _send_enter, which records to the log.
# shellcheck disable=SC2329 # invoked via BRIDGE_PICKER_SWEEP_*_FN env seam
r3_list_sessions() {
  printf '%s\n' "r3-fake-devchannels"
}
# shellcheck disable=SC2329 # invoked via BRIDGE_PICKER_SWEEP_*_FN env seam
r3_capture_pane() {
  printf '%s\n' "WARNING: Loading development channels"
  printf '%s\n' "❯ 1. I am using this for local development"
  printf '%s\n' "  2. Exit"
  printf '%s\n' "Enter to confirm · Esc to cancel"
}
# shellcheck disable=SC2329 # invoked via BRIDGE_PICKER_SWEEP_*_FN env seam
r3_send_enter() {
  printf '%s\n' "$1" >>"$R3_SEND_RECORD"
}
# shellcheck disable=SC2329 # invoked via BRIDGE_PICKER_SWEEP_*_FN env seam
r3_create_task() {
  printf '%s\n' "$1|$2|$3" >>"$R3_TASKS_RECORD"
}
export -f r3_list_sessions r3_capture_pane r3_send_enter r3_create_task

R3_STDERR="$R3_DIR/r3-stderr"
R3_RC=0
BRIDGE_PICKER_SWEEP_ENABLED=1 \
  BRIDGE_HOME="$R3_DIR" \
  BRIDGE_STATE_DIR="$R3_DIR/state" \
  BRIDGE_PICKER_SWEEP_LIST_SESSIONS_FN=r3_list_sessions \
  BRIDGE_PICKER_SWEEP_CAPTURE_PANE_FN=r3_capture_pane \
  BRIDGE_PICKER_SWEEP_SEND_ENTER_FN=r3_send_enter \
  BRIDGE_PICKER_SWEEP_CREATE_TASK_FN=r3_create_task \
  "$BASH_BIN" "$R3_DIR/scripts/picker-sweep.sh" 2>"$R3_STDERR" >/dev/null || R3_RC=$?

# Picker-sweep must exit 0 (no matching picker) AND must not have called
# _send_enter. If it had grabbed the dev-channels pane, R3_SEND_RECORD
# would contain "=r3-fake-devchannels:".
if [[ "$R3_RC" == "0" && ! -s "$R3_SEND_RECORD" ]]; then
  ok
else
  err "R3 picker-sweep grabbed dev-channels pane (rc=$R3_RC, sends=$(cat "$R3_SEND_RECORD" 2>/dev/null || true), stderr=$(cat "$R3_STDERR" 2>/dev/null || true))"
fi

# ---------------------------------------------------------------------------
# R4: timeout-still-works — pane has neither picker text nor claude
# foreground; watcher must exit with timeout exit code (2), not loop
# forever.
# ---------------------------------------------------------------------------
step "R4: watcher times out cleanly when neither picker nor foreground appears"
R4_SESSION="agb-825-r4-$$"
R4_DRIVER="$TMP_ROOT/r4-driver.sh"
cat >"$R4_DRIVER" <<R4DRV
#!/usr/bin/env bash
printf 'unrelated pane output — neither picker nor claude foreground here\n'
exec "$(command -v sleep)" 10
R4DRV
chmod +x "$R4_DRIVER"
tmux new-session -d -s "$R4_SESSION" "$R4_DRIVER"
SMOKE_SESSIONS+=("$R4_SESSION")
# Give the pane a moment to be ready.
wait_for_pane_text "$R4_SESSION" "unrelated pane output" 50 0.1 || true

R4_LOG="$TMP_ROOT/r4-watcher.log"
R4_RC=0
# foreground_timeout=1 second, poll=0.1s — watcher should finish in <2s.
R4_START="$(date +%s)"
run_controller_watcher_inline "$R4_SESSION" "r4-agent" 1 1 0.1 >"$R4_LOG" 2>&1 || R4_RC=$?
R4_ELAPSED=$(( $(date +%s) - R4_START ))

# Exit code 2 == "timeout-waiting-for-picker-or-foreground" sentinel from
# the inline watcher.
if [[ "$R4_RC" == "2" ]] && (( R4_ELAPSED < 5 )) \
  && grep -q '^timeout-waiting-for-picker-or-foreground$' "$R4_LOG"; then
  ok
else
  err "R4 timeout path: rc=$R4_RC elapsed=${R4_ELAPSED}s log=$(cat "$R4_LOG")"
fi

# ---------------------------------------------------------------------------
TOTAL=$((PASS + FAIL))
printf '\n# Issue #825 controller dev-channels auto-accept suite: %s/%s passed\n' "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
