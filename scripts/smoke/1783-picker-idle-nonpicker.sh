#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1783-picker-idle-nonpicker.sh — Issue #1783.
#
# The v0.16.8 no-LLM picker auto-resolve stage (#1762) escalated ordinary IDLE
# composer screens as "UNKNOWN stuck" — 19/22 sessions on a fleet within ~6min
# of enabling, recurring every ~5min. Root cause: bridge_picker_pane_looks_
# prompt_like() treated bare box-drawing glyphs + the bare '❯'/'›' selector as a
# prompt signal, but both engines' resting idle UI always contains those and is
# static, so the unknown-tick tracker fired for every idle session.
#
# This smoke covers the three #1783 fixes:
#   A — DEFAULT-CATALOG idle non_picker entries (claude-idle-ready /
#       codex-idle-ready): an idle composer classifies non_picker (hard
#       exclusion) so it can NEVER register as unknown-stuck.
#   B — TIGHTENED heuristic: a bare selector/border is no longer prompt-like; an
#       empty '❯' idle composer is NOT prompt-like, while a real picker
#       (selector + option text / numbered list / [y/n] / Press-Enter) IS.
#   C — STORM FUSE: a per-pass global cap on UNKNOWN escalations
#       (BRIDGE_PICKER_UNKNOWN_ESCALATION_CAP, default 3) — over the cap, the
#       pass emits ONE summarizing warn line instead of N high-priority tasks.
#   D — known-entry regression: the trust-prompt fixture still resolves (defer).
#
# tmux + queue are mocked exactly like 1762-picker-autoresolve.sh: fixture pane
# text, recorded keystrokes, a bridge-task.sh recorder stub. Footgun #11: the py
# helper is invoked file-as-argv; fixtures are written with printf to tempfiles.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (matches sibling smokes).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1783-picker-idle-nonpicker] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1783-picker-idle-nonpicker"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1783-picker-idle-nonpicker"

REPO_ROOT="$SMOKE_REPO_ROOT"
PICKER_SH="$REPO_ROOT/lib/bridge-picker.sh"
PICKER_PY="$REPO_ROOT/lib/bridge-picker.py"
CATALOG="$REPO_ROOT/runtime-templates/shared/picker-catalog.json"

smoke_assert_file_exists "$PICKER_SH" "lib/bridge-picker.sh present"
smoke_assert_file_exists "$PICKER_PY" "lib/bridge-picker.py present"
smoke_assert_file_exists "$CATALOG" "shipped catalog present"
smoke_require_cmd python3

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CATALOG" \
  || smoke_fail "shipped picker-catalog.json is not valid JSON"

export BRIDGE_SCRIPT_DIR="$REPO_ROOT"

# Source bridge-lib.sh at the TOP (a mid-run source could trigger the Bash 3.2->4
# re-exec and restart the whole smoke).
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"
declare -F bridge_picker_resolve_session >/dev/null \
  || smoke_fail "bridge_picker_resolve_session not defined after sourcing bridge-lib.sh"
declare -F bridge_picker_pane_looks_prompt_like >/dev/null \
  || smoke_fail "bridge_picker_pane_looks_prompt_like not defined"
declare -F bridge_picker_unknown_escalation_cap >/dev/null \
  || smoke_fail "bridge_picker_unknown_escalation_cap not defined (storm fuse missing)"

# Issue's sanitized idle captures (composer line + footer).
CLAUDE_IDLE=$'──────────────────── agent ──\n❯\n────────────────────────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents\n'
# EMPTY codex composer — the only shape the codex-idle-ready entry matches
# (empty-only is the P1-safe boundary: a real picker option row always has
# text after '›', so it can never masquerade as the composer line).
CODEX_IDLE=$'›\n\n  gpt-5.5 xhigh fast · ~/.agent-bridge/data/agents/x/workdir\n'
# GHOST-placeholder codex idle (the issue's sanitized capture). Deliberately
# NOT excluded by the catalog (documented residual): it reaches the unknown
# path and is bounded by the 2-tick/5-min budget + the per-pass storm fuse.
CODEX_IDLE_GHOST=$'› Run /review on my current changes\n\n  gpt-5.5 xhigh fast · ~/.agent-bridge/data/agents/x/workdir\n'
# A genuine novel confirm picker: option text after the selector.
REAL_PICKER=$'Proceed with this action?\n❯ 1. Yes, continue\n  2. No, cancel\n'

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

# shellcheck disable=SC2329
classify_shipped() {
  local engine="$1" pane="$2" pf
  pf="$(mktemp "$SMOKE_TMP_ROOT/pane.XXXXXX")"
  printf '%s' "$pane" >"$pf"
  python3 "$PICKER_PY" classify --engine "$engine" --pane-file "$pf" --catalog "$CATALOG"
}

# ---------------------------------------------------------------------
# A — DEFAULT-CATALOG idle non_picker entries classify the idle composers.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_a_idle_nonpicker_entries() {
  smoke_log "A: shipped catalog classifies both engines' idle composers as non_picker"
  local d
  d="$(classify_shipped claude "$CLAUDE_IDLE")"
  smoke_assert_eq "true"  "$(json_field "$d" non_picker)" "A: claude idle → non_picker"
  smoke_assert_eq "false" "$(json_field "$d" matched)"    "A: claude idle never registers as a stuck picker"
  smoke_assert_eq "claude-idle-ready" "$(json_field "$d" picker_id)" "A: claude idle → claude-idle-ready"

  d="$(classify_shipped codex "$CODEX_IDLE")"
  smoke_assert_eq "true"  "$(json_field "$d" non_picker)" "A: codex idle → non_picker"
  smoke_assert_eq "codex-idle-ready" "$(json_field "$d" picker_id)" "A: codex idle → codex-idle-ready"

  # Documented residual (empty-only boundary): GHOST placeholder text after '›'
  # is NOT excluded — it walks the unknown path (bounded by budget + storm fuse)
  # rather than risk a real '› /…' picker option row masquerading as idle.
  d="$(classify_shipped codex "$CODEX_IDLE_GHOST")"
  smoke_assert_eq "false" "$(json_field "$d" non_picker)" "A: codex GHOST idle is the documented fuse-bounded residual (not excluded)"

  # A genuine picker renders option text after the selector → does NOT match the
  # empty-composer idle entry, so it is still eligible for the unknown path.
  d="$(classify_shipped claude "$REAL_PICKER")"
  smoke_assert_eq "false" "$(json_field "$d" non_picker)" "A: real picker is NOT shadowed by the idle entry"
  smoke_assert_eq "false" "$(json_field "$d" matched)"    "A: real novel picker walks the unknown path (matched=false)"

  # codex review #1783 P2: the codex idle fingerprint anchors '›' to a LINE-LEADING
  # composer prompt, so a real codex picker that renders the selection caret '›'
  # MID-LINE on an option row (even if the ' · ~/' workdir footer persists) is NOT
  # mis-classified as codex-idle-ready — it stays eligible for the unknown path.
  local codex_real_picker=$'Update available — proceed?\n  1. Update now  › \n  2. Later\n  gpt-5.5 fast · ~/.agent-bridge/data/agents/x/workdir\n'
  d="$(classify_shipped codex "$codex_real_picker")"
  smoke_assert_eq "false" "$(json_field "$d" non_picker)" "A: codex mid-line caret picker NOT shadowed by codex-idle-ready"
}

# #1783 composite-pane handling (queue codex review PR #1785, two rounds). The
# idle non_picker entries are TAIL-SCOPED (foreground_guard): they short-circuit
# only when the idle composer/footer is the live bottom with no picker affordance
# at/below it. Two opposite cases must both be correct:
#
#  - FOREGROUND picker (a real stuck picker is the bottom-most live UI; the idle
#    composer is buried above it or absent) → NOT non_picker → escalates.
#    In a real TUI a live picker REPLACES the composer, so the idle signature is
#    not the tail. Fixtures put the picker options below the composer/footer.
CLAUDE_FOREGROUND_PICKER=$'──────────────────── agent ──\n❯\n────────────────────────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents\nProceed with action?\n❯ 1. Yes, continue\n  2. No, cancel\n'
CODEX_FOREGROUND_PICKER=$'  gpt-5.5 xhigh fast · ~/.agent-bridge/data/agents/x/workdir\nProceed with action?\n› Yes, continue\n› No, cancel\n'
# SINGLE-highlight foreground picker (queue codex review round): only the selected
# option carries the '❯' caret, the alternative is an unmarked row below the idle
# composer. The composer's own line is excluded, so this single caret-with-text
# row below it still counts as a real foreground picker → must escalate.
CLAUDE_FOREGROUND_SINGLE=$'──────────────────── agent ──\n❯\n────────────────────────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents\n❯ Continue where you left off\n  Start a new conversation\n'
# Codex foreground picker that keeps the PERSISTENT status footer BELOW the
# option rows (the queue codex review P1 layout). The option rows '› Yes' / '› No'
# carry no '/'-command and are not empty, so they no longer match the narrowed
# codex-idle composer fingerprint → the entry does not match → escalates.
CODEX_FOREGROUND_FOOTER_BELOW=$'Proceed with action?\n› Yes, continue\n› No, cancel\n  gpt-5.5 xhigh fast · ~/.agent-bridge/data/agents/x/workdir\n'
#  - STALE SCROLLBACK (menu-like text from PRIOR output sits ABOVE a live idle
#    ready composer/footer) → still non_picker → no false escalation. This is the
#    second-round guard: ordinary scrollback above the tail composer is ignored.
CLAUDE_STALE_SCROLLBACK=$'earlier run:\n  1. did thing\n  2. did other\nall done — press enter\n──────────────────── agent ──\n❯\n────────────────────────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents\n'
CODEX_STALE_SCROLLBACK=$'earlier:\n  1. option a\n  2. option b\n›\n\n  gpt-5.5 xhigh fast · ~/.agent-bridge/data/agents/x/workdir\n'

# ---------------------------------------------------------------------
# A3 — composite/foreground guard (queue codex review): a FOREGROUND picker (idle
# composer not the live tail) must classify NOT non_picker (reach the unknown
# path); STALE menu-like scrollback above a tail idle composer must stay
# non_picker; and the PURE idle pane stays non_picker.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_a3_composite_pane_not_shadowed() {
  smoke_log "A3: foreground picker → NOT non_picker; stale scrollback + pure idle → non_picker"
  local d
  # Foreground picker (idle composer not the tail) → escalate path.
  d="$(classify_shipped claude "$CLAUDE_FOREGROUND_PICKER")"
  smoke_assert_eq "false" "$(json_field "$d" non_picker)" "A3: claude foreground picker NOT non_picker"
  smoke_assert_eq "false" "$(json_field "$d" matched)"    "A3: claude foreground picker walks the unknown path"
  d="$(classify_shipped codex "$CODEX_FOREGROUND_PICKER")"
  smoke_assert_eq "false" "$(json_field "$d" non_picker)" "A3: codex foreground picker NOT non_picker"

  # Single-highlight foreground picker (only the selected option carries the
  # caret) below the idle composer → still NOT non_picker.
  d="$(classify_shipped claude "$CLAUDE_FOREGROUND_SINGLE")"
  smoke_assert_eq "false" "$(json_field "$d" non_picker)" "A3: claude single-caret foreground picker NOT non_picker"

  # Codex foreground picker with the PERSISTENT status footer BELOW the option
  # rows (queue codex review P1): option rows must not satisfy the narrowed
  # codex-idle composer fingerprint, so the pane is NOT non_picker.
  d="$(classify_shipped codex "$CODEX_FOREGROUND_FOOTER_BELOW")"
  smoke_assert_eq "false" "$(json_field "$d" non_picker)" "A3: codex picker with footer below options NOT non_picker (P1)"

  # Stale menu-like scrollback ABOVE a tail idle composer → still non_picker.
  d="$(classify_shipped claude "$CLAUDE_STALE_SCROLLBACK")"
  smoke_assert_eq "true" "$(json_field "$d" non_picker)" "A3: claude idle + stale scrollback above tail → non_picker"
  d="$(classify_shipped codex "$CODEX_STALE_SCROLLBACK")"
  smoke_assert_eq "true" "$(json_field "$d" non_picker)" "A3: codex idle + stale scrollback above tail → non_picker"

  # Control: the PURE idle panes MUST still be non_picker.
  d="$(classify_shipped claude "$CLAUDE_IDLE")"
  smoke_assert_eq "true" "$(json_field "$d" non_picker)" "A3: pure claude idle still non_picker (no false escalation)"
  d="$(classify_shipped codex "$CODEX_IDLE")"
  smoke_assert_eq "true" "$(json_field "$d" non_picker)" "A3: pure codex idle still non_picker (no false escalation)"
}

# ---------------------------------------------------------------------
# B — heuristic: an empty idle composer is NOT prompt-like; a real picker IS.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_b_heuristic_tightened() {
  smoke_log "B: bridge_picker_pane_looks_prompt_like excludes idle, accepts real affordances"
  # Idle composers must NOT be prompt-like (the #1783 false-positive source).
  bridge_picker_pane_looks_prompt_like "$CLAUDE_IDLE" \
    && smoke_fail "B: claude idle composer must NOT be prompt-like"
  # An empty composer wrapped in ANY supported border (light │, heavy ┃, ASCII |)
  # must NOT be prompt-like — the trailing border is stripped before the
  # non-empty-remainder check (queue codex review P2).
  local empty_box=$'╭──────────╮\n│ ❯        │\n╰──────────╯\n'
  bridge_picker_pane_looks_prompt_like "$empty_box" \
    && smoke_fail "B: empty light-box composer must NOT be prompt-like"
  local empty_box_heavy=$'┏━━━━━━━━━━┓\n┃ ❯        ┃\n┗━━━━━━━━━━┛\n'
  bridge_picker_pane_looks_prompt_like "$empty_box_heavy" \
    && smoke_fail "B: empty heavy-box (┃) composer must NOT be prompt-like"
  local empty_box_ascii=$'+----------+\n| \xe2\x9d\xaf        |\n+----------+\n'
  bridge_picker_pane_looks_prompt_like "$empty_box_ascii" \
    && smoke_fail "B: empty ASCII-box (|) composer must NOT be prompt-like"
  # Ordinary scrolling output must NOT be prompt-like.
  local plain=$'Running tests...\nAll 42 passed.\nDone.\n'
  bridge_picker_pane_looks_prompt_like "$plain" \
    && smoke_fail "B: ordinary output must NOT be prompt-like"

  # Real interactive affordances MUST be prompt-like.
  bridge_picker_pane_looks_prompt_like "$REAL_PICKER" \
    || smoke_fail "B: selector + option text must be prompt-like"
  local list_picker=$'❯ Continue where you left off\n  Start a new conversation\n'
  bridge_picker_pane_looks_prompt_like "$list_picker" \
    || smoke_fail "B: selector + option text (list) must be prompt-like"
  local numbered=$'Choose an option:\n  1. Yes\n  2. No\n'
  bridge_picker_pane_looks_prompt_like "$numbered" \
    || smoke_fail "B: numbered option list must be prompt-like"
  local yn=$'Update now? [Y/n]\n'
  bridge_picker_pane_looks_prompt_like "$yn" \
    || smoke_fail "B: [Y/n] confirm must be prompt-like"
  local enter=$'All set. Press Enter to continue\n'
  bridge_picker_pane_looks_prompt_like "$enter" \
    || smoke_fail "B: Press-Enter affordance must be prompt-like"
  # codex review #1783 P2: a LOWERCASE 'to continue' affordance must still count
  # (the tightening dropped the old broad '*to continue*' glyph; it is restored
  # case-insensitively so a novel 'press any key to continue' prompt still
  # escalates instead of being cleared every pass and stranding the agent).
  local lower_continue=$'build finished\npress any key to continue\n'
  bridge_picker_pane_looks_prompt_like "$lower_continue" \
    || smoke_fail "B: lowercase 'press any key to continue' must be prompt-like"
  local hit_continue=$'output\nhit any key to continue...\n'
  bridge_picker_pane_looks_prompt_like "$hit_continue" \
    || smoke_fail "B: lowercase 'hit any key to continue' must be prompt-like"

  # queue codex review #1785 P2: bridge_picker_pane_looks_prompt_like must NOT
  # leave a global RETURN trap on its early-success paths (it is a hot-path
  # helper; a leaked/clobbered RETURN trap corrupts the caller). Call it on a
  # MATCH (early return 0) and a NO-MATCH (final return 1), then assert no RETURN
  # trap leaked into this function's scope. Install a sentinel first so a clobber
  # is also caught.
  trap 'true' RETURN
  bridge_picker_pane_looks_prompt_like "$REAL_PICKER" >/dev/null || true  # early return 0
  local after_match; after_match="$(trap -p RETURN)"
  [[ "$after_match" == *"'true'"* ]] \
    || smoke_fail "B: prompt-like clobbered/dropped the caller RETURN trap on a match path ($after_match)"
  bridge_picker_pane_looks_prompt_like "$plain" >/dev/null || true       # final return 1
  local after_nomatch; after_nomatch="$(trap -p RETURN)"
  [[ "$after_nomatch" == *"'true'"* ]] \
    || smoke_fail "B: prompt-like clobbered/dropped the caller RETURN trap on a no-match path ($after_nomatch)"
  trap - RETURN
  smoke_log "B: heuristic idle-exclusion + affordance recognition + trap hygiene OK"
}

# ---------------------------------------------------------------------
# Shell-stage harness: mock the tmux + queue + agent-roster primitives so the
# resolver / scan run against fixture panes.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
setup_shell_stage() {
  export BRIDGE_PICKER_AUTORESOLVE=1
  export BRIDGE_PICKER_LOCAL_CATALOG="/nonexistent-local-catalog.json"
  export BRIDGE_PICKER_SETTLE_SECONDS=0
  export BRIDGE_ADMIN_AGENT_ID="admin"
  export BRIDGE_PICKER_STATE_DIR="$SMOKE_TMP_ROOT/pstate"

  # Point the shipped-catalog resolver at the REAL shipped catalog (this smoke
  # validates the shipped idle entries end-to-end through the shell stage).
  # shellcheck disable=SC2329
  bridge_picker_shipped_catalogs() { printf '%s\n' "$CATALOG"; }

  # tmux read primitive → per-session fixture pane. The resolver captures twice
  # per resolve (before + after), but the unknown/non_picker paths never key, so
  # returning the same fixture both times keeps the hash stable.
  SMOKE_PANE=""
  SMOKE_CAPTURE_COUNTER="$SMOKE_TMP_ROOT/capture-count"
  printf '0' >"$SMOKE_CAPTURE_COUNTER"
  # shellcheck disable=SC2329
  bridge_capture_recent() {
    printf '%s\n' "$SMOKE_PANE"
  }
  # shellcheck disable=SC2329
  bridge_tmux_session_exists() { return 0; }
  # shellcheck disable=SC2329
  bridge_tmux_session_inject_busy() { return 1; }
  # shellcheck disable=SC2329
  bridge_tmux_prepare_claude_session() { SMOKE_DEFER_CALLED=1; return 0; }
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
# A2 — end-to-end: an idle composer NEVER escalates as unknown-stuck across
# repeated ticks (unknown_stuck_minutes=0 so the only gate is the 2-tick budget).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_a2_idle_never_escalates() {
  smoke_log "A2: idle composer over many ticks → zero unknown-stuck escalations"
  # Use a catalog override that keeps the shipped idle entries but flattens the
  # unknown-stuck budget so the test would escalate WITHOUT the non_picker hard
  # exclusion. We layer a tiny defaults-only override via the local catalog.
  local zerobudget="$SMOKE_TMP_ROOT/zerobudget.json"
  printf '%s' '{"version":1,"defaults":{"unknown_stuck_minutes":0}}' >"$zerobudget"
  export BRIDGE_PICKER_LOCAL_CATALOG="$zerobudget"

  python3 "$PICKER_PY" clear-unknown --session sIdleC --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  python3 "$PICKER_PY" clear-unknown --session sIdleX --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  local before; before="$(count_escalations)"
  local i
  for i in 1 2 3 4; do
    SMOKE_KEYS=""
    resolve_tick "agentIdleC" "sIdleC" "claude" "$CLAUDE_IDLE"
    resolve_tick "agentIdleX" "sIdleX" "codex" "$CODEX_IDLE"
    smoke_assert_eq "" "${SMOKE_KEYS:-}" "A2: idle composers send ZERO keystrokes (tick $i)"
  done
  smoke_assert_eq "$before" "$(count_escalations)" "A2: idle composers NEVER escalate as unknown-stuck"

  export BRIDGE_PICKER_LOCAL_CATALOG="/nonexistent-local-catalog.json"
}

# ---------------------------------------------------------------------
# A4 — end-to-end foreground-picker escalation (queue codex review): a FOREGROUND
# picker (idle composer not the live tail) is NOT hard-excluded and, held
# unchanged past the unknown budget, DOES escalate exactly once — proving the
# foreground guard flows through to the unknown-stuck path, not just classify.
# The STALE-scrollback control (menu-like text above a tail idle composer) must
# NOT escalate in the same run.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_a4_composite_escalates_e2e() {
  smoke_log "A4: foreground picker → escalates; stale scrollback → never escalates"
  local zerobudget="$SMOKE_TMP_ROOT/zerobudget.json"
  printf '%s' '{"version":1,"defaults":{"unknown_stuck_minutes":0}}' >"$zerobudget"
  export BRIDGE_PICKER_LOCAL_CATALOG="$zerobudget"

  python3 "$PICKER_PY" clear-unknown --session sFgC --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  python3 "$PICKER_PY" clear-unknown --session sFgX --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  python3 "$PICKER_PY" clear-unknown --session sStaleC --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true

  # claude foreground picker: tick 1 arms (2-tick budget), tick 2 escalates once.
  local b; b="$(count_escalations)"
  SMOKE_KEYS=""
  resolve_tick "agentFgC" "sFgC" "claude" "$CLAUDE_FOREGROUND_PICKER"
  smoke_assert_eq "$b" "$(count_escalations)" "A4: claude foreground picker tick 1 arms (no escalation yet)"
  resolve_tick "agentFgC" "sFgC" "claude" "$CLAUDE_FOREGROUND_PICKER"
  (( $(count_escalations) == b + 1 )) || smoke_fail "A4: claude foreground picker must escalate exactly once (before=$b after=$(count_escalations))"
  smoke_assert_eq "" "${SMOKE_KEYS:-}" "A4: foreground-picker escalation sends ZERO keystrokes"

  # codex foreground picker: same two-tick escalation.
  local b2; b2="$(count_escalations)"
  resolve_tick "agentFgX" "sFgX" "codex" "$CODEX_FOREGROUND_PICKER"
  smoke_assert_eq "$b2" "$(count_escalations)" "A4: codex foreground picker tick 1 arms (no escalation yet)"
  resolve_tick "agentFgX" "sFgX" "codex" "$CODEX_FOREGROUND_PICKER"
  (( $(count_escalations) == b2 + 1 )) || smoke_fail "A4: codex foreground picker must escalate exactly once (before=$b2 after=$(count_escalations))"

  # single-highlight foreground picker (only the selected row carries the caret).
  python3 "$PICKER_PY" clear-unknown --session sFgS --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  local b4; b4="$(count_escalations)"
  resolve_tick "agentFgS" "sFgS" "claude" "$CLAUDE_FOREGROUND_SINGLE"
  resolve_tick "agentFgS" "sFgS" "claude" "$CLAUDE_FOREGROUND_SINGLE"
  (( $(count_escalations) == b4 + 1 )) || smoke_fail "A4: single-caret foreground picker must escalate exactly once (before=$b4 after=$(count_escalations))"

  # Stale scrollback above a tail idle composer must NEVER escalate, even across
  # several ticks (it is non_picker — the second-round false-positive guard).
  local b3; b3="$(count_escalations)"
  local i
  for i in 1 2 3; do
    resolve_tick "agentStaleC" "sStaleC" "claude" "$CLAUDE_STALE_SCROLLBACK"
  done
  smoke_assert_eq "$b3" "$(count_escalations)" "A4: idle + stale scrollback NEVER escalates (non_picker)"

  export BRIDGE_PICKER_LOCAL_CATALOG="/nonexistent-local-catalog.json"
}

# ---------------------------------------------------------------------
# C — storm fuse: > cap novel unknown-stuck sessions in ONE pass → exactly one
# summarizing warn line, the cap respected (cap escalations, the rest suppressed).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_c_storm_fuse() {
  smoke_log "C: per-pass unknown-escalation cap → cap respected + one summary warn"
  # A roster of N agents, each parked on the SAME novel prompt-like (but not
  # idle, not catalogued) screen — the worst case a heuristic regression creates.
  # Drive a full scan pass twice (the unknown-tick budget is 2) so all are stuck.
  local zerobudget="$SMOKE_TMP_ROOT/zerobudget.json"
  printf '%s' '{"version":1,"defaults":{"unknown_stuck_minutes":0}}' >"$zerobudget"
  export BRIDGE_PICKER_LOCAL_CATALOG="$zerobudget"
  export BRIDGE_PICKER_UNKNOWN_ESCALATION_CAP=3

  smoke_assert_eq "3" "$(bridge_picker_unknown_escalation_cap)" "C: cap reads the env knob"

  # A novel prompt-like screen that matches NO catalog entry (option text after a
  # selector → prompt-like, but not an idle composer and not catalogued).
  local novel=$'Pick an action:\n❯ Do the thing\n  Do nothing\n'

  BRIDGE_AGENT_IDS=(a1 a2 a3 a4 a5 a6)
  # shellcheck disable=SC2329
  bridge_agent_engine() { printf 'claude'; }
  # shellcheck disable=SC2329
  bridge_agent_session() { printf 'sess-%s' "$1"; }
  local a
  for a in "${BRIDGE_AGENT_IDS[@]}"; do
    python3 "$PICKER_PY" clear-unknown --session "sess-$a" --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  done
  SMOKE_PANE="$novel"

  # Capture warns: bridge_warn writes to stderr. Run the two passes capturing
  # stderr from the SECOND pass (when every session is unknown-stuck).
  local before; before="$(count_escalations)"
  # Pass 1: first unknown tick for each → no escalation yet (2-tick budget).
  bridge_picker_scan_all_sessions >/dev/null 2>&1 || true
  smoke_assert_eq "$before" "$(count_escalations)" "C: first pass arms the budget, no escalation"

  # Pass 2: every session now unknown-stuck → cap escalations + suppress the rest.
  local warn_file="$SMOKE_TMP_ROOT/storm-warn.txt"
  bridge_picker_scan_all_sessions >/dev/null 2>"$warn_file" || true
  local escalated; escalated=$(( $(count_escalations) - before ))
  smoke_assert_eq "3" "$escalated" "C: exactly cap(=3) unknown escalations filed this pass"

  # Exactly ONE summarizing warn line naming the suppressed count.
  local summary_lines=0 line
  while IFS= read -r line; do
    [[ "$line" == *"UNKNOWN-escalation cap"* ]] && summary_lines=$((summary_lines + 1))
  done <"$warn_file"
  smoke_assert_eq "1" "$summary_lines" "C: exactly ONE storm-fuse summary warn line"
  grep -q "suppressed 3 additional" "$warn_file" \
    || smoke_fail "C: summary warn must name the suppressed count (6 stuck - 3 cap = 3)"

  # Anti-starvation (codex review #1783 P2): the 3 sessions that ESCALATED on pass 2
  # cleared their own timers and must re-elapse the 2-tick budget, while the 3
  # SUPPRESSED sessions kept their elapsed budget and stay stuck. So pass 3 must
  # surface the previously-suppressed sessions (3 more escalations) — the stable
  # scan order rotates instead of starving the later agents forever.
  local before3; before3="$(count_escalations)"
  bridge_picker_scan_all_sessions >/dev/null 2>&1 || true
  local escalated3; escalated3=$(( $(count_escalations) - before3 ))
  smoke_assert_eq "3" "$escalated3" "C: pass 3 rotates — the previously-suppressed sessions now escalate (no starvation)"

  unset BRIDGE_PICKER_UNKNOWN_ESCALATION_CAP
  export BRIDGE_PICKER_LOCAL_CATALOG="/nonexistent-local-catalog.json"
  unset -f bridge_agent_engine bridge_agent_session 2>/dev/null || true
}

# ---------------------------------------------------------------------
# D — known-entry regression: the trust-prompt fixture still resolves (defer to
# the existing trust machinery), unaffected by the idle entries + heuristic.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_d_known_entry_regression() {
  smoke_log "D: trust-prompt fixture still classifies + defers (no regression)"
  python3 "$PICKER_PY" clear-state --session sTrust --state-dir "$BRIDGE_PICKER_STATE_DIR" >/dev/null 2>&1 || true
  SMOKE_KEYS=""
  SMOKE_DEFER_CALLED=0
  local before; before="$(count_escalations)"
  # The shipped claude-trust-folder entry: 'Quick safety check:' + 'Yes, I trust
  # this folder'. stuck_confirm_ticks default is 2 → drive two identical ticks.
  local trust=$'Quick safety check:\n❯ 1. Yes, I trust this folder\n  2. No\n'
  resolve_tick "agentTrust" "sTrust" "claude" "$trust"
  resolve_tick "agentTrust" "sTrust" "claude" "$trust"
  smoke_assert_eq "1" "${SMOKE_DEFER_CALLED:-0}" "D: trust prompt routed to existing claude machinery (defer)"
  smoke_assert_eq "" "${SMOKE_KEYS:-}" "D: defer sends NO picker keystrokes"
  smoke_assert_eq "$before" "$(count_escalations)" "D: defer does not escalate"
}

smoke_run "A: shipped idle non_picker entries" test_a_idle_nonpicker_entries
smoke_run "A3: composite pane not shadowed" test_a3_composite_pane_not_shadowed
smoke_run "B: heuristic tightened (idle excluded)" test_b_heuristic_tightened

setup_shell_stage

smoke_run "A2: idle composer never escalates" test_a2_idle_never_escalates
smoke_run "A4: composite pane escalates e2e" test_a4_composite_escalates_e2e
smoke_run "C: storm fuse caps + one warn line" test_c_storm_fuse
smoke_run "D: known trust entry still resolves" test_d_known_entry_regression

smoke_log "all #1783 idle-nonpicker / composite-shadow / heuristic / storm-fuse / regression checks pass"
exit 0
