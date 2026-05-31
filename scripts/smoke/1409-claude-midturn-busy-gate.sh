#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1409-claude-midturn-busy-gate.sh — Issue #1409.
#
# Upstream bug (filed by @Mejurix on v0.15.0-rc1): daemon inbox-nudges to a
# BUSY (mid-turn) Claude agent land as text in the composer but never submit;
# the operator must press Enter manually. Idle agents are unaffected. Audit:
#   daemon session_nudge_dropped <admin> reason=submit_lost_post_grace idle_seconds=0
#
# Root cause: bridge_tmux_session_inject_busy (lib/bridge-tmux.sh) for
# engine=claude only treated the session as busy when the composer already
# held text (bridge_tmux_session_has_pending_input) OR a recent keypress was
# detected. It did NOT detect Claude Code's mid-turn state — the spinner
# banner ("Working" / "Imagining…") with the "esc to interrupt" hint. So
# while Claude is generating, the gate reported NOT busy, the daemon typed
# the nudge + C-m, and Claude Code dropped the mid-turn submit — text
# stranded, logged submit_lost_post_grace.
#
# Fix: bridge_tmux_session_inject_busy now (for engine=claude) captures the
# joined plain pane text and reports BUSY when bridge_tmux_claude_capture_
# is_midturn matches. That detector is REGION-AWARE (codex review #1409 r1):
# it is built on the shared substring primitive bridge_tmux_capture_has_
# working_banner — the SAME literal match the codex submit path
# (bridge_tmux_codex_submit_landed) uses, factored into one helper so the
# two callers cannot drift — but it additionally rejects a stale banner that
# sits in scrollback above a now-clean composer, so an idle prompt is never
# falsely reported busy. When busy is reported, the existing pending-
# attention spool path (bridge_tmux_send_and_submit) re-delivers the nudge
# once the prompt is clean.
#
# Test plan:
#   T1 — Live banner→busy: engine=claude + pane's live tail is "esc to
#        interrupt" → bridge_tmux_session_inject_busy returns 0 (busy →
#        spool).
#   T2 — Live "Working" spinner→busy: engine=claude → returns 0 (busy).
#   T3 — Clean prompt→not busy: engine=claude + a clean idle composer (no
#        banner, no pending input, no keypress, detached) → returns 1
#        (NOT busy → normal nudge submits). Regression guard for the
#        idle-submit path.
#   T4 — Codex unchanged: engine=codex + the SAME banner text must NOT make
#        inject_busy branch on the claude-only path (the codex submit
#        semantics are handled at submit-landed time, not here) → returns 1.
#   T5 — Scrollback false-positive guard (codex r1): a stale banner ABOVE a
#        clean composer, ordinary "Working" prose above a clean prompt →
#        BOTH return 1 (not busy); a live banner BELOW an older prompt
#        (fresh turn) re-arms → returns 0 (busy).
#   T6 — Predicate units: the shared substring primitive matches anywhere
#        (codex semantics), while the region-aware detector rejects stale
#        scrollback the primitive intentionally still matches.
#   T7 — Factoring teeth: bridge_tmux_codex_submit_landed delegates to the
#        shared primitive (not a duplicated inline match), AND
#        bridge_tmux_session_inject_busy routes through the region-aware
#        detector (NOT the bare primitive on a wide capture). A future PR
#        that re-inlines the match, or points the claude gate back at the
#        scrollback-unsafe primitive, trips this.
#
# Footgun #11 (heredoc-stdin deadlock class): this fixture uses no
# heredoc-stdin into subprocess and no `<<<` here-strings into bridge
# functions. Banner fixtures are plain string locals.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (matches sibling smokes).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1409-claude-midturn-busy-gate] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1409-claude-midturn-busy-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1409-claude-midturn-busy-gate"

REPO_ROOT="$SMOKE_REPO_ROOT"
TMUX_LIB="$REPO_ROOT/lib/bridge-tmux.sh"

smoke_assert_file_exists "$TMUX_LIB" "lib/bridge-tmux.sh present"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

if ! declare -F bridge_tmux_session_inject_busy >/dev/null; then
  smoke_fail "bridge_tmux_session_inject_busy not defined after sourcing bridge-lib.sh"
fi
if ! declare -F bridge_tmux_capture_has_working_banner >/dev/null; then
  smoke_fail "bridge_tmux_capture_has_working_banner not defined (shared helper missing)"
fi

# ---------------------------------------------------------------------
# Stubs: isolate the busy-gate's banner branch from a live tmux session.
# The clean-prompt gates (pending-input, attached-count, recent-keypress)
# are stubbed to their not-busy defaults so the ONLY remaining signal is
# the mid-turn banner. The claude gate captures plain (joined) pane text
# via bridge_capture_recent, fed here from $SMOKE_PANE_TEXT.
# ---------------------------------------------------------------------
SMOKE_PANE_TEXT=""

# shellcheck disable=SC2329
bridge_capture_recent() { printf '%s\n' "$SMOKE_PANE_TEXT"; }
# shellcheck disable=SC2329
bridge_tmux_session_has_pending_input() { return 1; }
# shellcheck disable=SC2329
bridge_tmux_session_attached_count() { printf '0'; }
# shellcheck disable=SC2329
bridge_tmux_session_recent_keypress() { return 1; }

# Banner fixture matching the issue's pane capture (mid-turn — banner is the
# live tail, no clean composer prompt below it).
BANNER_ESC=$'· Imagining… (10m 41s · ↓ 36.0k tokens)\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt'
# A "Working" spinner banner (the other mid-turn form).
BANNER_WORKING=$'✻ Working… (3s · ↑ 1.2k tokens)\n  esc to interrupt'
# A clean idle composer — boxed placeholder prompt, no spinner / interrupt.
CLEAN_PROMPT=$'╭─────────────────────────╮\n│ > Try "edit <file>"     │\n╰─────────────────────────╯\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'
# STALE banner sitting in scrollback ABOVE a now-clean composer. This is the
# codex review #1409 r1 false-positive: a whole-capture substring match would
# wrongly report busy and strand nudges forever. The region-aware detector
# must report NOT busy here.
STALE_BANNER_ABOVE_CLEAN=$'· Imagining… (10m · esc to interrupt)\n[earlier turn finished]\n╭─────────────╮\n│ > Try "edit" │\n╰─────────────╯'
# Ordinary "Working" prose in an agent response, above a clean bare prompt.
ORDINARY_WORKING_ABOVE_CLEAN=$'Assistant: I am Working on the plan now.\n> '
# A fresh turn STARTED below an older prompt: banner is the live tail again →
# must re-arm busy (region detector resets on the prompt then sees the banner).
BANNER_BELOW_OLD_PROMPT=$'╭─────────────╮\n│ > old prompt │\n╰─────────────╯\n· Reticulating splines… esc to interrupt'

# ---------------------------------------------------------------------
# T1 — Live banner ("esc to interrupt") → busy for engine=claude.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t1_esc_banner_busy() {
  smoke_log "T1: claude live 'esc to interrupt' banner → inject_busy=0 (busy)"
  SMOKE_PANE_TEXT="$BANNER_ESC"
  local rc=0
  bridge_tmux_session_inject_busy "smoke-claude" "claude" 3 || rc=$?
  smoke_assert_eq "0" "$rc" "T1: live mid-turn banner must report busy (rc=0)"
}

# ---------------------------------------------------------------------
# T2 — Live "Working" spinner banner → busy for engine=claude.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t2_working_banner_busy() {
  smoke_log "T2: claude live 'Working' spinner banner → inject_busy=0 (busy)"
  SMOKE_PANE_TEXT="$BANNER_WORKING"
  local rc=0
  bridge_tmux_session_inject_busy "smoke-claude" "claude" 3 || rc=$?
  smoke_assert_eq "0" "$rc" "T2: live Working spinner must report busy (rc=0)"
}

# ---------------------------------------------------------------------
# T3 — Clean idle prompt → NOT busy (regression guard for normal nudges).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t3_clean_prompt_not_busy() {
  smoke_log "T3: claude clean idle prompt (no banner) → inject_busy=1 (not busy)"
  SMOKE_PANE_TEXT="$CLEAN_PROMPT"
  local rc=0
  bridge_tmux_session_inject_busy "smoke-claude" "claude" 3 || rc=$?
  smoke_assert_eq "1" "$rc" "T3: clean prompt must NOT report busy (rc=1)"
}

# ---------------------------------------------------------------------
# T4 — Codex: the claude-only banner branch does not change codex.
# Same banner text, engine=codex, no pending input / keypress / attach →
# inject_busy returns 1 (the codex banner is handled at submit-landed
# time, not in this gate).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t4_codex_unchanged() {
  smoke_log "T4: codex + banner text → inject_busy=1 (claude-only branch not taken)"
  SMOKE_PANE_TEXT="$BANNER_ESC"
  local rc=0
  bridge_tmux_session_inject_busy "smoke-codex" "codex" 3 || rc=$?
  smoke_assert_eq "1" "$rc" "T4: codex inject_busy must not flip on the claude banner branch"
}

# ---------------------------------------------------------------------
# T5 — Scrollback false-positive guard (codex review #1409 r1). A stale
# banner ABOVE a now-clean composer, AND ordinary "Working" prose above a
# clean prompt, must BOTH report NOT busy through the full inject-busy
# gate — otherwise legitimate nudges spool forever.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t5_stale_scrollback_not_busy() {
  smoke_log "T5: stale banner above clean composer → inject_busy=1 (not busy)"
  SMOKE_PANE_TEXT="$STALE_BANNER_ABOVE_CLEAN"
  local rc=0
  bridge_tmux_session_inject_busy "smoke-claude" "claude" 3 || rc=$?
  smoke_assert_eq "1" "$rc" "T5: stale banner in scrollback must NOT report busy"

  smoke_log "T5: ordinary 'Working' prose above clean prompt → not busy"
  SMOKE_PANE_TEXT="$ORDINARY_WORKING_ABOVE_CLEAN"
  rc=0
  bridge_tmux_session_inject_busy "smoke-claude" "claude" 3 || rc=$?
  smoke_assert_eq "1" "$rc" "T5: ordinary 'Working' text above a clean prompt must NOT report busy"

  smoke_log "T5: banner BELOW an older prompt (fresh turn) → busy"
  SMOKE_PANE_TEXT="$BANNER_BELOW_OLD_PROMPT"
  rc=0
  bridge_tmux_session_inject_busy "smoke-claude" "claude" 3 || rc=$?
  smoke_assert_eq "0" "$rc" "T5: a live banner below an older prompt must re-arm busy"
}

# ---------------------------------------------------------------------
# T6 — Predicate units: the shared substring primitive and the
# region-aware claude detector.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t6_predicate_units() {
  smoke_log "T6: shared substring primitive truth table"
  local rc=0
  bridge_tmux_capture_has_working_banner "$BANNER_ESC" || rc=$?
  smoke_assert_eq "0" "$rc" "T6: primitive matches 'esc to interrupt'"
  rc=0
  bridge_tmux_capture_has_working_banner "$BANNER_WORKING" || rc=$?
  smoke_assert_eq "0" "$rc" "T6: primitive matches 'Working'"
  rc=0
  bridge_tmux_capture_has_working_banner "$CLEAN_PROMPT" || rc=$?
  smoke_assert_eq "1" "$rc" "T6: primitive rejects a clean prompt"
  rc=0
  bridge_tmux_capture_has_working_banner "" || rc=$?
  smoke_assert_eq "1" "$rc" "T6: primitive rejects empty input"

  smoke_log "T6: region-aware bridge_tmux_claude_capture_is_midturn truth table"
  rc=0
  bridge_tmux_claude_capture_is_midturn "$BANNER_ESC" || rc=$?
  smoke_assert_eq "0" "$rc" "T6: region detector reports live esc banner mid-turn"
  rc=0
  bridge_tmux_claude_capture_is_midturn "$BANNER_WORKING" || rc=$?
  smoke_assert_eq "0" "$rc" "T6: region detector reports live Working banner mid-turn"
  # The region detector REJECTS what the bare substring primitive accepts:
  rc=0
  bridge_tmux_capture_has_working_banner "$STALE_BANNER_ABOVE_CLEAN" || rc=$?
  smoke_assert_eq "0" "$rc" "T6: substring primitive (intentionally) still matches stale scrollback"
  rc=0
  bridge_tmux_claude_capture_is_midturn "$STALE_BANNER_ABOVE_CLEAN" || rc=$?
  smoke_assert_eq "1" "$rc" "T6: region detector rejects stale banner above a clean composer"
}

# ---------------------------------------------------------------------
# T7 — Teeth: the codex submit path still delegates to the shared
# substring primitive, and the claude gate routes through the region-
# aware detector (NOT the bare primitive on a wide capture). A PR that
# re-inlines the literal match in either path, or points the claude gate
# back at the scrollback-unsafe primitive, trips this.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t7_factoring_teeth() {
  smoke_log "T7: codex delegates to primitive; claude gate uses region detector"
  if ! grep -q "bridge_tmux_capture_has_working_banner" "$TMUX_LIB"; then
    smoke_fail "T7: shared primitive bridge_tmux_capture_has_working_banner missing from lib/bridge-tmux.sh"
  fi
  if ! grep -q "bridge_tmux_claude_capture_is_midturn" "$TMUX_LIB"; then
    smoke_fail "T7: region-aware detector bridge_tmux_claude_capture_is_midturn missing from lib/bridge-tmux.sh"
  fi
  # Codex submit path delegates to the primitive (formerly an inline match).
  if ! grep -q "if bridge_tmux_capture_has_working_banner \"\$ansi_text\"; then" "$TMUX_LIB"; then
    smoke_fail "T7: bridge_tmux_codex_submit_landed no longer delegates to the shared primitive (re-inlined match?)"
  fi
  # The claude busy-gate must route through the region-aware detector.
  if ! grep -q "if bridge_tmux_claude_capture_is_midturn \"\$recent\"; then" "$TMUX_LIB"; then
    smoke_fail "T7: bridge_tmux_session_inject_busy no longer routes through the region-aware detector (scrollback false-positive risk)"
  fi
}

smoke_run "T1: live 'esc to interrupt' banner → busy (claude)" test_t1_esc_banner_busy
smoke_run "T2: live 'Working' spinner → busy (claude)" test_t2_working_banner_busy
smoke_run "T3: clean prompt → not busy (claude, regression guard)" test_t3_clean_prompt_not_busy
smoke_run "T4: codex unchanged on claude banner branch" test_t4_codex_unchanged
smoke_run "T5: stale scrollback → not busy (codex r1 false-positive guard)" test_t5_stale_scrollback_not_busy
smoke_run "T6: predicate units (primitive + region-aware detector)" test_t6_predicate_units
smoke_run "T7: teeth — codex primitive + claude region-aware factoring" test_t7_factoring_teeth

smoke_log "all T1-T7 pass"
exit 0
