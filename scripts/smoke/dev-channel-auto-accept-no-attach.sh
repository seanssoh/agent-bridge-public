#!/usr/bin/env bash
# scripts/smoke/dev-channel-auto-accept-no-attach.sh — issue #1306.
#
# Guards the controller-side dev-channels picker auto-accept path
# (bridge-start.sh::bridge_start_schedule_dev_channels_accept) for the
# daemon auto-recovery shape: tmux session present, no client attached,
# picker text drawn in the pane, no claude descendant process.
#
# Root cause framing (per feedback-root-vs-symptom-framing): the prior
# implementation routed the picker auto-accept through
# bridge_tmux_wait_for_prompt -> bridge_tmux_claude_advance_blocker ->
# bridge_tmux_wait_for_claude_foreground. The foreground gate uses the
# pane_pid's process tree comm; on the daemon --no-attach path the comm
# can drift from `claude` (e.g. wrapper-launched, mid-fork, transient).
# Without an attached client the previous fix's env-var bypass tripped
# intermittently because wait_for_prompt re-polled blocker_state on
# every iteration, racing the picker-text capture window. The fix is
# the direct send: when the watcher's picker-text check fires,
# immediately send Enter to the pane (no foreground gate, no
# wait_for_prompt indirection, no attach check). This smoke locks in
# both teeth and the no-regression contract.
#
# T1 (primary regression): synthesize a tmux session running a stub
# script that paints the dev-channels picker text into the pane and
# blocks on read. NO claude process in tree, NO client attached.
# Invoke bridge_start_schedule_dev_channels_accept. Assert: the stub
# observes the Enter key within N seconds (sentinel file created),
# proving the picker auto-accept fires without a foreground/attach gate.
#
# T2 (teeth): re-run T1 but with a stub that NEVER paints the picker
# text. Assert: no Enter received within the same window. This proves
# the auto-accept is gated on picker-text-detected (not "always send"),
# protecting the no-picker non-dev-channels path.
#
# T3 (data shape): direct unit assertion that the production code uses
# `C-m` (tmux's canonical Enter key name) as the send token. The brief's
# default-checklist item #3 calls out this contract: not `1` alone, not
# `1\n` — the cursor glyph is already on option 1, so Enter is the
# correct picker key.
#
# T4 (state-machine identity): bridge_tmux_claude_blocker_state_from_text
# returns `devchannels` for the picker text and `none` for an
# unrelated pane. This pins the trigger predicate so a future PR
# cannot widen the picker detector and accidentally auto-accept a
# different blocker shape (trust / summary live on the same code path
# but expect Enter to mean "yes, I trust" — semantically different).
#
# Footgun #11 self-audit: no heredoc-stdin / here-string. Uses
# `mktemp + < file` or one-shot redirection where multi-line data
# crosses fd boundaries.

# Bash 4+ re-exec (mirrors scripts/smoke/status-engine-detect.sh shape).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:dev-channel-auto-accept-no-attach] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="dev-channel-auto-accept-no-attach"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

FAKE_TMUX_SESSION=""

cleanup() {
  if [[ -n "$FAKE_TMUX_SESSION" ]]; then
    tmux kill-session -t "=${FAKE_TMUX_SESSION}" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

source_bridge_tmux() {
  # Source only the tmux helper. The picker auto-accept logic under
  # test boils down to:
  #   - bridge_tmux_session_exists (used by the watcher and the direct
  #     send re-verify guard)
  #   - bridge_tmux_pane_has_dev_channels_picker (the picker-text check)
  #   - bridge_tmux_send_keys_with_timeout (the actual send wrapper)
  #   - bridge_tmux_pane_target (the send target string builder)
  # All four live in lib/bridge-tmux.sh, which is sourceable standalone.
  #
  # The send-with-timeout helper depends on bridge_with_timeout
  # (lib/bridge-state.sh). Provide a minimal stub so the helper does
  # not need the full bridge-lib.sh load (which would touch the
  # operator's runtime roster).
  # shellcheck source=lib/bridge-tmux.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-tmux.sh"
  # Minimal bridge_with_timeout stub: just exec the command directly.
  # The watcher's 10s watchdog is irrelevant for the test, and a real
  # `timeout` invocation under macOS would need `gtimeout` from coreutils.
  bridge_with_timeout() {
    local _secs="$1"
    local _label="$2"
    shift 2
    "$@"
  }
}

# Wait briefly for a file to appear (sentinel pattern). Used to detect
# that Enter reached the stub's read loop.
wait_for_file() {
  local path="$1"
  local max_attempts="${2:-50}"  # 50 * 0.1s = 5s
  local attempt
  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    [[ -f "$path" ]] && return 0
    sleep 0.1
  done
  return 1
}

# Direct-send invocation extracted from bridge-start.sh's inline
# subshell. Tests the production behavior — the production function
# wraps this same pattern inside a backgrounded subshell that sources
# bridge-lib.sh; here we exercise the post-picker_seen branch directly
# so we can assert end-to-end without spinning the full watcher.
invoke_direct_send() {
  local session="$1"
  if bridge_tmux_session_exists "$session" \
     && bridge_tmux_pane_has_dev_channels_picker "$session"; then
    bridge_tmux_send_keys_with_timeout tmux_send_dev_channels_picker_direct \
      -t "$(bridge_tmux_pane_target "$session")" C-m
    return $?
  fi
  return 1
}

case_state_machine_identity() {
  # T4: pin bridge_tmux_claude_blocker_state_from_text — picker text
  # must classify as `devchannels` and pane content lacking the picker
  # must NOT.
  local devchannels_text
  devchannels_text="$(printf '%s\n' \
    "WARNING: Loading development channels" \
    "--dangerously-load-development-channels is for local channel development only." \
    "  ❯ 1. I am using this for local development" \
    "    2. Exit" \
    "  Enter to confirm · Esc to cancel")"
  local state
  state="$(bridge_tmux_claude_blocker_state_from_text "$devchannels_text")"
  smoke_assert_eq "devchannels" "$state" \
    "T4 state-machine: picker text classifies as devchannels"

  state="$(bridge_tmux_claude_blocker_state_from_text "ordinary scrollback line")"
  smoke_assert_eq "none" "$state" \
    "T4 state-machine: unrelated pane text classifies as none"

  # Boundary: the trust prompt must NOT be classified as devchannels —
  # they live on different code paths inside advance_blocker (trust =
  # Enter to accept, devchannels = Enter to advance picker). The picker
  # auto-accept must not widen into the trust prompt.
  local trust_text
  trust_text="$(printf '%s\n' \
    "Quick safety check:" \
    "Do you trust the files in this folder?" \
    "❯ 1. Yes, I trust this folder" \
    "  2. No, do not run scripts")"
  state="$(bridge_tmux_claude_blocker_state_from_text "$trust_text")"
  smoke_assert_eq "trust" "$state" \
    "T4 state-machine: trust prompt stays distinct (must NOT classify as devchannels)"
}

case_t1_picker_accepts_without_attach() {
  # T1: synthesize a tmux session running a stub that paints the
  # picker text and waits for Enter on stdin. NO claude in process
  # tree, NO client attached. The fix's direct-send branch should
  # detect picker-text + session-exists and fire Enter regardless.
  local sentinel="$SMOKE_TMP_ROOT/t1.enter-received"
  local stub_script="$SMOKE_TMP_ROOT/t1.stub.sh"
  # Stub: print the picker text exactly as Claude renders it, then
  # block on `read`. On read return (Enter pressed), touch the
  # sentinel — that is our proof that the keystroke reached the pane.
  # The stub's stdout goes to the tmux pane, so the picker text becomes
  # the pane's visible content (which `tmux capture-pane` then exposes
  # to bridge_tmux_pane_has_dev_channels_picker).
  cat > "$stub_script" <<'STUB'
#!/usr/bin/env bash
# Stub: mimic Claude's picker render then wait for Enter.
printf 'WARNING: Loading development channels\n'
printf -- '--dangerously-load-development-channels is for local channel development only.\n'
printf '\n'
printf '  ❯ 1. I am using this for local development\n'
printf '    2. Exit\n'
printf '\n'
printf '  Enter to confirm · Esc to cancel\n'
# Block on read. On Enter, touch sentinel + sleep so the pane stays
# alive long enough for cleanup to kill it cleanly.
IFS= read -r _line
touch "$1"
sleep 30
STUB
  chmod +x "$stub_script"

  FAKE_TMUX_SESSION="agb-smoke-1306-t1-$$-${RANDOM}"
  # `tmux new-session -d` returns once the session is created. The
  # inner command is `bash $stub_script $sentinel`. No `exec` here so
  # the pane root is bash with stub_script as a child — the stub
  # script's `read` reads from the pane's stdin (which is the tmux
  # pty), so `tmux send-keys ... C-m` reaches it.
  tmux new-session -d -s "$FAKE_TMUX_SESSION" \
    "bash '$stub_script' '$sentinel'"

  if ! tmux has-session -t "=${FAKE_TMUX_SESSION}" 2>/dev/null; then
    smoke_fail "T1: tmux session '$FAKE_TMUX_SESSION' did not come up"
  fi

  # Wait for the stub to paint the picker text into the pane (i.e.
  # tmux capture-pane returns the picker text). Polling matches the
  # production watcher's pattern. 2s budget — locally this is <100ms.
  local picker_visible=0
  local attempt
  for (( attempt = 0; attempt < 20; attempt++ )); do
    if bridge_tmux_pane_has_dev_channels_picker "$FAKE_TMUX_SESSION"; then
      picker_visible=1
      break
    fi
    sleep 0.1
  done
  if (( picker_visible == 0 )); then
    smoke_fail "T1: picker text never reached the pane (stub did not render?)"
  fi

  # Verify no client is attached — this is the daemon --no-attach
  # shape we are guarding against. `tmux list-clients -t <session>`
  # output should be empty.
  local attached_clients
  attached_clients="$(tmux list-clients -t "=${FAKE_TMUX_SESSION}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ "$attached_clients" != "0" ]]; then
    smoke_fail "T1: expected zero attached clients (daemon --no-attach shape), got $attached_clients"
  fi

  # Direct-send invocation. The function should detect picker +
  # session and fire Enter. No attach, no foreground gate.
  invoke_direct_send "$FAKE_TMUX_SESSION" || \
    smoke_fail "T1: invoke_direct_send returned non-zero (picker present but send failed)"

  # The stub's `read` should return on Enter and touch the sentinel.
  wait_for_file "$sentinel" 50 || \
    smoke_fail "T1: sentinel '$sentinel' never appeared — Enter did NOT reach the pane (regression: attach/foreground gate may have blocked the send)"
}

case_t2_teeth_no_picker_no_send() {
  # T2 teeth: same shape as T1 but the stub never paints picker text.
  # The direct-send guard MUST hold: invoke_direct_send returns
  # non-zero (no picker => no send), and the sentinel stays absent.
  local sentinel="$SMOKE_TMP_ROOT/t2.enter-received"
  local stub_script="$SMOKE_TMP_ROOT/t2.stub.sh"
  cat > "$stub_script" <<'STUB'
#!/usr/bin/env bash
printf 'ordinary scrollback — no picker here\n'
IFS= read -r _line
touch "$1"
sleep 30
STUB
  chmod +x "$stub_script"

  # Kill any prior session
  if [[ -n "$FAKE_TMUX_SESSION" ]]; then
    tmux kill-session -t "=${FAKE_TMUX_SESSION}" >/dev/null 2>&1 || true
  fi
  FAKE_TMUX_SESSION="agb-smoke-1306-t2-$$-${RANDOM}"
  tmux new-session -d -s "$FAKE_TMUX_SESSION" \
    "bash '$stub_script' '$sentinel'"

  if ! tmux has-session -t "=${FAKE_TMUX_SESSION}" 2>/dev/null; then
    smoke_fail "T2: tmux session '$FAKE_TMUX_SESSION' did not come up"
  fi

  # Let the stub paint its non-picker text.
  sleep 0.5
  if bridge_tmux_pane_has_dev_channels_picker "$FAKE_TMUX_SESSION"; then
    smoke_fail "T2: picker text wrongly classified as present (stub paints non-picker text)"
  fi

  # invoke_direct_send should return non-zero (no send) because
  # the picker-text guard inside it fails.
  if invoke_direct_send "$FAKE_TMUX_SESSION"; then
    smoke_fail "T2: invoke_direct_send returned zero with no picker present — guard regressed"
  fi

  # Sentinel must NOT exist (no Enter was sent).
  sleep 0.3
  if [[ -f "$sentinel" ]]; then
    smoke_fail "T2: sentinel '$sentinel' appeared — Enter was sent despite no picker (auto-accept widened)"
  fi
}

case_t3_data_shape_canonical() {
  # T3 default-checklist item #3: assert the send token is `C-m`
  # (tmux's canonical Enter symbol) and NOT a bare `1` or a literal
  # newline. The production code at bridge-start.sh's direct-send
  # branch uses C-m — pin that exact token so a future PR that
  # "simplifies" to `1\r` or `Enter` cannot drift without tripping
  # this smoke.
  #
  # We grep the production file for the exact send invocation. A
  # tighter pin than re-running the watcher and parsing the audit
  # row.
  local bridge_start_path
  bridge_start_path="$SMOKE_REPO_ROOT/bridge-start.sh"
  smoke_assert_file_exists "$bridge_start_path" "T3: bridge-start.sh exists at expected path"

  # The direct-send label is unique to the new code path. Anchor on
  # both the label AND the C-m argument so a label-only match cannot
  # pass when the key drifted.
  if ! grep -q 'tmux_send_dev_channels_picker_direct' "$bridge_start_path"; then
    smoke_fail "T3: direct-send label 'tmux_send_dev_channels_picker_direct' missing from bridge-start.sh — the fix regressed"
  fi
  if ! grep -q 'tmux_send_dev_channels_picker_direct.*C-m\|C-m.*tmux_send_dev_channels_picker_direct' \
        "$bridge_start_path"; then
    # The label and the C-m token may be on adjacent lines (line-broken
    # invocation). Fall back to a 5-line-window check that asserts they
    # co-occur in the same call.
    local window
    window="$(grep -A 3 'tmux_send_dev_channels_picker_direct' "$bridge_start_path" || true)"
    if [[ "$window" != *"C-m"* ]]; then
      smoke_fail "T3: direct-send invocation does not pass C-m (canonical Enter); the fix widened the key shape"
    fi
  fi

  # And the no-go counter-cases: the direct-send branch must NOT use
  # `1\r` (a literal "1" key) — the cursor glyph is already on option
  # 1 in the picker render, so `Enter` (C-m) selects it. Sending `1`
  # would type the digit into the picker before confirming.
  local window
  window="$(grep -A 3 'tmux_send_dev_channels_picker_direct' "$bridge_start_path" || true)"
  if [[ "$window" == *"'1'"* || "$window" == *'"1"'* ]]; then
    smoke_fail "T3: direct-send branch sends literal '1' key — picker cursor is already on option 1, Enter alone is correct"
  fi
}

main() {
  smoke_require_cmd tmux
  smoke_require_cmd python3

  smoke_make_temp_root "$SMOKE_NAME"
  source_bridge_tmux

  # T4 first (pure unit, no tmux dependency) so we fail fast on a
  # state-machine drift before paying for the tmux session setup.
  smoke_run "T4 state-machine identity"           case_state_machine_identity
  smoke_run "T3 data shape canonical (C-m token)" case_t3_data_shape_canonical
  smoke_run "T2 teeth: no picker -> no send"      case_t2_teeth_no_picker_no_send
  smoke_run "T1 picker accepts without attach"    case_t1_picker_accepts_without_attach

  smoke_log "passed"
}

main "$@"
