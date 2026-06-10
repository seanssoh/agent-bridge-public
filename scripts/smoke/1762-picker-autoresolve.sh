#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1762-picker-autoresolve.sh — Issue #1762.
#
# No-LLM picker auto-resolve: a fingerprint catalog + policy resolver replaces
# the continuous LLM sweeper. The daemon captures each managed session's pane
# (last ~40 lines), matches it against a data-only catalog, confirms the
# picker is STUCK (same fingerprint + unchanged pane hash across N ticks), and
# resolves it via the engine-aware tmux submit primitives — with three safety
# rails (post-resolve verification, anti-loop, destructive-guard). Unknown /
# auth-surface / verification-failed states escalate a queue task to the admin.
#
# This smoke mocks tmux entirely: bridge_capture_recent feeds fixture pane
# text, the key primitives record what they would send, and bridge-task.sh is
# stubbed to record an escalation instead of touching the queue. It exercises:
#   T1  — fingerprint match / no-match (python classify)
#   T2  — non_picker banner never registers as a stuck picker
#   T3  — disabled catalog entry no-ops (no match)
#   T4  — stuck-confirmation: N ticks + unchanged hash = stuck; a changing
#         pane hash is NOT stuck; picker change resets the counter
#   T5  — policy dispatch: auto_resolve sends the right key sequence
#         (select_first + confirm) through the tmux primitive layer
#   T6  — post-resolve verification rail: if the pane STILL matches a picker
#         after keying, do NOT re-key — escalate
#   T7  — anti-loop: same picker resolved M times in the window escalates
#   T8  — destructive-guard: destructive option selected → escalate, no keys
#   T9  — unknown-but-stuck (escalate policy) files the admin escalation task
#   T10 — defer policy routes to the existing trust/summary machinery, no keys
#
# Footgun #11 (heredoc-stdin deadlock class): the python helper is invoked
# file-as-argv; no heredoc-stdin into subprocess. Catalog/pane fixtures are
# written with printf to tempfiles.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (matches sibling smokes).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1762-picker-autoresolve] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1762-picker-autoresolve"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1762-picker-autoresolve"

REPO_ROOT="$SMOKE_REPO_ROOT"
PICKER_SH="$REPO_ROOT/lib/bridge-picker.sh"
PICKER_PY="$REPO_ROOT/lib/bridge-picker.py"
CATALOG="$REPO_ROOT/runtime-templates/shared/picker-catalog.json"

smoke_assert_file_exists "$PICKER_SH" "lib/bridge-picker.sh present"
smoke_assert_file_exists "$PICKER_PY" "lib/bridge-picker.py present"
smoke_assert_file_exists "$CATALOG" "shipped catalog present"
smoke_require_cmd python3

# The shipped catalog must be valid JSON.
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CATALOG" \
  || smoke_fail "shipped picker-catalog.json is not valid JSON"

# Make BRIDGE_SCRIPT_DIR point at the repo so the shell stage can find the py
# helper + shipped catalog when sourced under bridge-lib.sh.
export BRIDGE_SCRIPT_DIR="$REPO_ROOT"

# Source bridge-lib.sh at the TOP (before any test runs), matching the sibling
# smokes. bridge-lib.sh may re-exec the shell (Bash 3.2->4 upgrade, #1454); a
# mid-run source would re-exec and restart the whole smoke. Sourcing here means
# the re-exec (if any) happens once, cleanly, before T1.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"
declare -F bridge_picker_resolve_session >/dev/null \
  || smoke_fail "bridge_picker_resolve_session not defined after sourcing bridge-lib.sh"
declare -F bridge_tmux_send_picker_key >/dev/null \
  || smoke_fail "bridge_tmux_send_picker_key not defined (tmux primitive missing)"

# A scratch test catalog (independent of the shipped one) with enabled +
# disabled + non_picker + destructive entries, so the tests are stable even as
# the shipped catalog's [approx] entries flip enabled/disabled.
# The shell-stage tests use stuck_confirm_ticks=1 so a single tick is
# immediately "stuck" — that lets each test drive one resolve call without
# pre-seeding a hash that must exactly match the resolver's own capture. (The
# 2-tick confirmation itself is covered directly by T4 against the py helper.)
TESTCAT="$SMOKE_TMP_ROOT/test-catalog.json"
printf '%s' '{
  "version": 1,
  "defaults": {"stuck_confirm_ticks": 1, "antiloop_window_seconds": 120, "antiloop_max_resolves": 3},
  "entries": [
    {"picker_id":"t-update","engine":"codex","enabled":true,"match":["Update now"],"policy":"auto_resolve","keys":["confirm"],"post_resolve_verify":true},
    {"picker_id":"t-list","engine":"claude","enabled":true,"match":["Continue where you left off","Start a new conversation"],"destructive_match":["Start a new conversation"],"policy":"auto_resolve","keys":["select_first","confirm"],"post_resolve_verify":true},
    {"picker_id":"t-disabled","engine":"codex","enabled":false,"match":["Disabled prompt"],"policy":"auto_resolve","keys":["confirm"]},
    {"picker_id":"t-banner","engine":"claude","enabled":true,"match":["Auto-update failed"],"policy":"non_picker"},
    {"picker_id":"t-auth","engine":"codex","enabled":true,"match":["session has expired"],"policy":"escalate"},
    {"picker_id":"t-defer","engine":"claude","enabled":true,"match":["Quick safety check"],"policy":"defer","defer_to":"trust_machinery"}
  ]
}' >"$TESTCAT"

# shellcheck disable=SC2329
py_classify() {
  local engine="$1" pane="$2"
  local pf
  pf="$(mktemp "$SMOKE_TMP_ROOT/pane.XXXXXX")"
  printf '%s' "$pane" >"$pf"
  python3 "$PICKER_PY" classify --engine "$engine" --pane-file "$pf" --catalog "$TESTCAT"
}

# shellcheck disable=SC2329
json_field() {
  local json="$1" key="$2"
  printf '%s' "$json" | python3 -c '
import json,sys
o=json.loads(sys.stdin.read() or "{}")
v=o.get(sys.argv[1])
sys.stdout.write("true" if v is True else "false" if v is False else "" if v is None else " ".join(map(str,v)) if isinstance(v,list) else str(v))
' "$key"
}

# ---------------------------------------------------------------------
# T1 — fingerprint match / no-match.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t1_match_nomatch() {
  smoke_log "T1: fingerprint match + no-match"
  local d
  d="$(py_classify codex $'output\nUpdate now? [Y/n]\n')"
  smoke_assert_eq "true" "$(json_field "$d" matched)" "T1: 'Update now' matches t-update"
  smoke_assert_eq "t-update" "$(json_field "$d" picker_id)" "T1: picker_id is t-update"
  d="$(py_classify codex $'just a normal prompt\n> \n')"
  smoke_assert_eq "false" "$(json_field "$d" matched)" "T1: ordinary prompt does not match"
  # Engine gate: a codex fingerprint must not match for a claude session.
  d="$(py_classify claude $'output\nUpdate now? [Y/n]\n')"
  smoke_assert_eq "false" "$(json_field "$d" matched)" "T1: codex fingerprint not matched for claude engine"
}

# ---------------------------------------------------------------------
# T2 — non_picker banner never registers as a stuck picker.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t2_non_picker_banner() {
  smoke_log "T2: non_picker status banner → matched=false, non_picker=true"
  local d
  d="$(py_classify claude $'working...\n  Auto-update failed - Run /doctor\n> \n')"
  smoke_assert_eq "false" "$(json_field "$d" matched)" "T2: banner must NOT report matched (never stuck)"
  smoke_assert_eq "true" "$(json_field "$d" non_picker)" "T2: banner reports non_picker=true"
}

# ---------------------------------------------------------------------
# T3 — disabled catalog entry no-ops.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t3_disabled_entry() {
  smoke_log "T3: disabled entry is never matched"
  local d
  d="$(py_classify codex $'Disabled prompt visible\n')"
  smoke_assert_eq "false" "$(json_field "$d" matched)" "T3: disabled entry must not match"
}

# ---------------------------------------------------------------------
# T4 — stuck-confirmation state machine.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t4_stuck_confirmation() {
  smoke_log "T4: N ticks + unchanged hash = stuck; changing hash NOT stuck"
  local sd="$SMOKE_TMP_ROOT/state4" out
  out="$(python3 "$PICKER_PY" tick --session s1 --picker-id pA --pane-hash H1 --stuck-confirm-ticks 2 --state-dir "$sd")"
  smoke_assert_eq "false" "$(json_field "$out" stuck)" "T4: first tick not yet stuck"
  out="$(python3 "$PICKER_PY" tick --session s1 --picker-id pA --pane-hash H1 --stuck-confirm-ticks 2 --state-dir "$sd")"
  smoke_assert_eq "true" "$(json_field "$out" stuck)" "T4: second identical tick is stuck"
  # A changing pane hash (live redraw) must reset the counter → not stuck.
  out="$(python3 "$PICKER_PY" tick --session s1 --picker-id pA --pane-hash H2 --stuck-confirm-ticks 2 --state-dir "$sd")"
  smoke_assert_eq "false" "$(json_field "$out" stuck)" "T4: changed pane hash resets (not stuck)"
  smoke_assert_eq "1" "$(json_field "$out" ticks)" "T4: changed hash → ticks back to 1"
  # A different picker id also resets.
  out="$(python3 "$PICKER_PY" tick --session s1 --picker-id pB --pane-hash H2 --stuck-confirm-ticks 2 --state-dir "$sd")"
  smoke_assert_eq "1" "$(json_field "$out" ticks)" "T4: picker change resets ticks to 1"
}

# ---------------------------------------------------------------------
# Shell-stage harness: source bridge-lib.sh, then override the tmux + queue
# primitives so the resolver runs against fixture panes.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
setup_shell_stage() {
  # bridge-lib.sh is already sourced at the top of the smoke (avoids a mid-run
  # re-exec). This only installs the tmux/queue mocks + picker env.
  export BRIDGE_PICKER_AUTORESOLVE=1
  export BRIDGE_PICKER_LOCAL_CATALOG="/nonexistent-local-catalog.json"
  export BRIDGE_PICKER_SETTLE_SECONDS=0
  export BRIDGE_ADMIN_AGENT_ID="admin"
  export BRIDGE_PICKER_STATE_DIR="$SMOKE_TMP_ROOT/pstate"

  # Point the shipped-catalog resolver at our test catalog only: unset the
  # runtime shared dir and override the source-tree path lookup by shadowing
  # bridge_picker_shipped_catalogs.
  # shellcheck disable=SC2329
  bridge_picker_shipped_catalogs() { printf '%s\n' "$TESTCAT"; }

  # tmux read primitive → fixture pane(s). SMOKE_PANE is the "before" pane;
  # SMOKE_PANE_AFTER is what the re-capture returns (defaults to a clean prompt
  # so post-resolve verification passes unless a test sets it to a picker).
  SMOKE_PANE=""
  SMOKE_PANE_AFTER=$'╭─────────╮\n│ > Try   │\n╰─────────╯\n'
  # The resolver calls bridge_capture_recent inside command substitution (a
  # subshell), so a plain shell counter would not persist across calls. Use a
  # file-backed counter: capture #1 returns the "before" pane, #2+ the "after".
  SMOKE_CAPTURE_COUNTER="$SMOKE_TMP_ROOT/capture-count"
  printf '0' >"$SMOKE_CAPTURE_COUNTER"
  # shellcheck disable=SC2329
  bridge_capture_recent() {
    local n
    n="$(cat "$SMOKE_CAPTURE_COUNTER" 2>/dev/null || printf '0')"
    n=$((n + 1))
    printf '%s' "$n" >"$SMOKE_CAPTURE_COUNTER"
    if (( n == 1 )); then
      printf '%s\n' "$SMOKE_PANE"
    else
      printf '%s\n' "$SMOKE_PANE_AFTER"
    fi
  }
  # Not busy / session exists / not midturn → let the resolver proceed.
  # shellcheck disable=SC2329
  bridge_tmux_session_exists() { return 0; }
  # shellcheck disable=SC2329
  bridge_tmux_session_inject_busy() { return 1; }
  # shellcheck disable=SC2329
  bridge_tmux_prepare_claude_session() { SMOKE_DEFER_CALLED=1; return 0; }

  # Record keystrokes instead of sending them.
  SMOKE_KEYS=""
  # shellcheck disable=SC2329
  bridge_tmux_send_picker_key() {
    local token="$4"
    SMOKE_KEYS="${SMOKE_KEYS}${SMOKE_KEYS:+ }${token}"
    return 0
  }
  # shellcheck disable=SC2329
  bridge_tmux_send_submit_key() { SMOKE_KEYS="${SMOKE_KEYS}${SMOKE_KEYS:+ }submit"; return 0; }

  # Record escalation instead of filing a real queue task. The escalator
  # resolves bridge-task.sh from BRIDGE_PICKER_TASK_SCRIPT when set (the test
  # override), so point that at a recorder — the real queue is never touched.
  SMOKE_ESCALATIONS="$SMOKE_TMP_ROOT/escalations.log"
  : >"$SMOKE_ESCALATIONS"
  export SMOKE_ESCALATIONS
  local fake_task="$SMOKE_TMP_ROOT/bridge-task-recorder.sh"
  cat >"$fake_task" <<'TASKEOF'
#!/usr/bin/env bash
# Recorder stub for bridge-task.sh in the picker smoke.
printf 'escalation:' >>"$SMOKE_ESCALATIONS"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) printf ' title=%q' "$2" >>"$SMOKE_ESCALATIONS"; shift 2;;
    --to) printf ' to=%q' "$2" >>"$SMOKE_ESCALATIONS"; shift 2;;
    --body-file) printf ' bodyfile=%q' "$2" >>"$SMOKE_ESCALATIONS"; shift 2;;
    *) shift;;
  esac
done
printf '\n' >>"$SMOKE_ESCALATIONS"
exit 0
TASKEOF
  chmod +x "$fake_task"
  export BRIDGE_PICKER_TASK_SCRIPT="$fake_task"
}

# shellcheck disable=SC2329
count_escalations() {
  # grep -c prints "0" AND exits 1 on no-match — under `set -e`/`pipefail` a
  # `$(grep ...)` assignment would abort. Read the file and count in-process
  # instead so the function always succeeds with a single clean integer.
  local n=0 line
  if [[ -f "${SMOKE_ESCALATIONS:-}" ]]; then
    while IFS= read -r line; do
      [[ "$line" == escalation:* ]] && n=$((n + 1))
    done <"$SMOKE_ESCALATIONS"
  fi
  printf '%s' "$n"
}

# ---------------------------------------------------------------------
# T5 — policy dispatch: auto_resolve sends the right keys (mocked tmux).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t5_policy_dispatch_keys() {
  smoke_log "T5: auto_resolve (list picker) sends select_first + confirm"
  SMOKE_KEYS=""
  printf '0' >"$SMOKE_CAPTURE_COUNTER"
  SMOKE_PANE=$'pick one:\n❯ Continue where you left off\n  Start a new conversation\n'
  # clean pane after keying → post-resolve verify passes
  SMOKE_PANE_AFTER=$'╭───╮\n│ > │\n╰───╯\n'
  local before_esc; before_esc="$(count_escalations)"
  bridge_picker_resolve_session "agentT5" "sT5" "claude" || true
  smoke_assert_contains "$SMOKE_KEYS" "select_first" "T5: sent select_first"
  smoke_assert_contains "$SMOKE_KEYS" "confirm" "T5: sent confirm"
  smoke_assert_eq "$before_esc" "$(count_escalations)" "T5: clean post-resolve → no escalation"
}

# ---------------------------------------------------------------------
# T6 — post-resolve verification rail: pane STILL a picker after keying →
# do NOT re-key blindly, escalate.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t6_post_resolve_verify() {
  smoke_log "T6: post-resolve pane still a picker → escalate (no blind re-key)"
  python3 "$PICKER_PY" clear-state --session sT6 --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  SMOKE_KEYS=""
  printf '0' >"$SMOKE_CAPTURE_COUNTER"
  SMOKE_PANE=$'codex:\nUpdate now? [Y/n]\n'
  # After keying, the pane STILL shows a picker (mismatch case).
  SMOKE_PANE_AFTER=$'codex:\nUpdate now? [Y/n]\n'
  # Pre-seed one tick so the resolver acts on this call.
  local before_esc; before_esc="$(count_escalations)"
  bridge_picker_resolve_session "agentT6" "sT6" "codex" || true
  local after_esc; after_esc="$(count_escalations)"
  (( after_esc > before_esc )) || smoke_fail "T6: post-resolve verify failure must escalate (before=$before_esc after=$after_esc)"
}

# ---------------------------------------------------------------------
# T7 — anti-loop: after max resolves in the window, escalate not re-key.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t7_antiloop_escalates() {
  smoke_log "T7: anti-loop ceiling → escalate"
  python3 "$PICKER_PY" clear-state --session sT7 --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  # Pre-fill the anti-loop counter to the ceiling (max_resolves default 3): two
  # prior resolves means the next attempt is the 3rd → tripped.
  python3 "$PICKER_PY" antiloop --session sT7 --picker-id t-update --window-seconds 120 --max-resolves 3 --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null
  python3 "$PICKER_PY" antiloop --session sT7 --picker-id t-update --window-seconds 120 --max-resolves 3 --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null
  SMOKE_KEYS=""
  printf '0' >"$SMOKE_CAPTURE_COUNTER"
  SMOKE_PANE=$'codex:\nUpdate now? [Y/n]\n'
  SMOKE_PANE_AFTER=$'codex:\nUpdate now? [Y/n]\n'
  local before_esc; before_esc="$(count_escalations)"
  bridge_picker_resolve_session "agentT7" "sT7" "codex" || true
  (( $(count_escalations) > before_esc )) || smoke_fail "T7: anti-loop ceiling must escalate"
  smoke_assert_not_contains "$SMOKE_KEYS" "confirm" "T7: anti-loop tripped → NO keystrokes sent"
}

# ---------------------------------------------------------------------
# T8 — destructive-guard: destructive option selected → escalate, no keys.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t8_destructive_guard() {
  smoke_log "T8: destructive option selected → escalate, no keys"
  python3 "$PICKER_PY" clear-state --session sT8 --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  SMOKE_KEYS=""
  printf '0' >"$SMOKE_CAPTURE_COUNTER"
  # The DESTRUCTIVE option carries the selection glyph ❯ → must refuse.
  SMOKE_PANE=$'pick one:\n  Continue where you left off\n❯ Start a new conversation\n'
  SMOKE_PANE_AFTER=$'╭───╮\n│ > │\n╰───╯\n'
  local before_esc; before_esc="$(count_escalations)"
  bridge_picker_resolve_session "agentT8" "sT8" "claude" || true
  (( $(count_escalations) > before_esc )) || smoke_fail "T8: destructive selection must escalate"
  smoke_assert_not_contains "$SMOKE_KEYS" "confirm" "T8: destructive guard → NO keystrokes sent"
}

# ---------------------------------------------------------------------
# T9 — unknown-but-stuck / escalate policy files the admin task.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t9_escalate_policy() {
  smoke_log "T9: escalate-policy picker (auth surface) files admin task, no keys"
  python3 "$PICKER_PY" clear-state --session sT9 --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  SMOKE_KEYS=""
  printf '0' >"$SMOKE_CAPTURE_COUNTER"
  SMOKE_PANE=$'codex:\nYour session has expired. Sign in again.\n'
  SMOKE_PANE_AFTER=$'codex:\nYour session has expired. Sign in again.\n'
  local before_esc; before_esc="$(count_escalations)"
  bridge_picker_resolve_session "agentT9" "sT9" "codex" || true
  (( $(count_escalations) > before_esc )) || smoke_fail "T9: escalate policy must file an admin task"
  smoke_assert_eq "" "$SMOKE_KEYS" "T9: escalate policy sends ZERO keystrokes"
}

# ---------------------------------------------------------------------
# T10 — defer policy routes to existing machinery, no picker keystrokes.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t10_defer_policy() {
  smoke_log "T10: defer policy → existing machinery, no picker keys, no escalation"
  python3 "$PICKER_PY" clear-state --session sT10 --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  SMOKE_KEYS=""
  SMOKE_DEFER_CALLED=0
  printf '0' >"$SMOKE_CAPTURE_COUNTER"
  SMOKE_PANE=$'Quick safety check: do you trust this folder?\n❯ Yes, I trust this folder\n'
  SMOKE_PANE_AFTER=$'╭───╮\n│ > │\n╰───╯\n'
  local before_esc; before_esc="$(count_escalations)"
  bridge_picker_resolve_session "agentT10" "sT10" "claude" || true
  smoke_assert_eq "1" "${SMOKE_DEFER_CALLED:-0}" "T10: defer routed to existing claude machinery"
  smoke_assert_eq "" "$SMOKE_KEYS" "T10: defer sends NO picker keystrokes"
  smoke_assert_eq "$before_esc" "$(count_escalations)" "T10: defer does not escalate"
}

# ---------------------------------------------------------------------
# T11 — tmux primitive teeth: the resolver routes keystrokes through the
# bridge-tmux.sh primitive (never raw send-keys) and the daemon wires the
# cadence-gated phase.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t11_teeth() {
  smoke_log "T11: keystroke layer + daemon wiring teeth"
  grep -q "bridge_tmux_send_picker_key" "$PICKER_SH" \
    || smoke_fail "T11: resolver no longer uses the tmux primitive bridge_tmux_send_picker_key"
  # No raw `tmux send-keys` in the resolver — but ignore comment lines (the
  # file's own contract note literally spells out "NO raw tmux send-keys").
  if grep -Ev '^\s*#' "$PICKER_SH" | grep -Eq "tmux[[:space:]]+send-keys"; then
    smoke_fail "T11: lib/bridge-picker.sh issues raw 'tmux send-keys' (must route through bridge-tmux.sh)"
  fi
  grep -q "bridge_picker_scan_all_sessions" "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "T11: daemon tick no longer calls bridge_picker_scan_all_sessions"
  grep -q "bridge_daemon_pass_due picker_autoresolve" "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "T11: daemon picker phase is not cadence-gated"
}

smoke_run "T1: fingerprint match/no-match" test_t1_match_nomatch
smoke_run "T2: non_picker banner never stuck" test_t2_non_picker_banner
smoke_run "T3: disabled entry no-op" test_t3_disabled_entry
smoke_run "T4: stuck-confirmation (ticks + hash)" test_t4_stuck_confirmation

setup_shell_stage

smoke_run "T5: auto_resolve key dispatch" test_t5_policy_dispatch_keys
smoke_run "T6: post-resolve verification rail" test_t6_post_resolve_verify
smoke_run "T7: anti-loop escalation" test_t7_antiloop_escalates
smoke_run "T8: destructive-guard" test_t8_destructive_guard
smoke_run "T9: escalate policy files admin task" test_t9_escalate_policy
smoke_run "T10: defer policy → existing machinery" test_t10_defer_policy
smoke_run "T11: tmux primitive + daemon wiring teeth" test_t11_teeth

smoke_log "all T1-T11 pass"
exit 0
