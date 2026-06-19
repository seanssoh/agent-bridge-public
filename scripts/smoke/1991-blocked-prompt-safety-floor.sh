#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1991-blocked-prompt-safety-floor.sh — Issue #1991 SAFETY FLOOR.
#
# A blocked interactive prompt (Claude: dev-channels picker / trust / summary /
# permission / feedback / context-pressure / billing / unknown — or Codex:
# hook-trust / unknown-modal, #2007) that the existing best-effort auto-accept
# fails to clear must become a LOUD operator escalation within ~2 minutes,
# INDEPENDENTLY of the blocked agent — never a silent stuck pane. This floor is
# OBSERVE-ONLY: it never sends keys, never selects a UI option, and never asks
# an LLM to read the pane.
#
# This smoke implements the design's 11-case matrix. It runs entirely in an
# isolated BRIDGE_HOME and STUBS bridge-notify.sh so NO real Discord/Telegram
# message is ever sent — it asserts the DAEMON called the transport directly,
# independent of any live agent/pane. It also stubs the tmux capture/session
# helpers so the all-pane sweep can be driven deterministically through ticks.
#
# Footgun #11: no heredoc-stdin into a subprocess; fixtures use printf/Write.

set -euo pipefail

# Re-exec under Bash 4+ for assoc arrays + [[ == ]] glob semantics.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1991-blocked-prompt-safety-floor] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1991-blocked-prompt-safety-floor"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1991-blocked-prompt-safety-floor"

REPO_ROOT="$SMOKE_REPO_ROOT"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
STALL_PY="$REPO_ROOT/bridge-stall.py"
TMUX_SH="$REPO_ROOT/lib/bridge-tmux.sh"

smoke_assert_file_exists "$DAEMON_SH" "bridge-daemon.sh present"
smoke_assert_file_exists "$STALL_PY" "bridge-stall.py present"
smoke_assert_file_exists "$TMUX_SH" "lib/bridge-tmux.sh present"
smoke_require_cmd python3

# ===========================================================================
# Part 1: detect-only classifier (cases 1, 5, 6, 7, 10, 11). Pure-text — no
# daemon, no tmux. These guard the confidence gates / false-positive rejection
# / untrusted-text handling / coarse-token compatibility.
# ===========================================================================

# shellcheck disable=SC2329
detect() {
  # echoes the shell-format detect-prompt output for a fixture on stdin
  printf '%s\n' "$1" | python3 "$STALL_PY" detect-prompt --format shell
}

# shellcheck disable=SC2329
detect_codex() {
  # Issue #2007: same as detect() but routed through the Codex detector.
  printf '%s\n' "$1" | python3 "$STALL_PY" detect-prompt --engine codex --format shell
}

# detect-prompt --format shell emits JSON-quoted values (KEY="value"). Extract
# the value for KEY, stripping the surrounding double quotes.
# shellcheck disable=SC2329
prompt_field() {
  local key="$1" payload="$2"
  printf '%s\n' "$payload" | sed -n "s/^${key}=//p" | head -n 1 | sed 's/^"//; s/"$//'
}

# shellcheck disable=SC2329
test_05_non_picker_false_positives() {
  # numbered list / docs / scrollback / ready prompt must NOT detect.
  local NUMBERED="Here are the next steps:
  1. Read the file
  2. Edit it
  3. Run the tests"
  local DOCS="See the README for details. Option 1 is the default; option 2 is advanced."
  local READY="Resume from summary (recommended)
Resume full session as-is
❯ waiting for your input"

  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "$NUMBERED")")" \
    "normal numbered list does NOT detect"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "$DOCS")")" \
    "documentation snippet does NOT detect"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "$READY")")" \
    "ready prompt at tail does NOT detect (even with modal text in scrollback)"
}

# shellcheck disable=SC2329
test_06_engine_gate_claude_and_codex() {
  # Issue #2007: the floor now covers Claude AND Codex panes (detect-only for
  # both). Assert the daemon's engine gate admits claude|codex and skips any
  # other engine. The actual codex routing + non-claude/codex skip is exercised
  # behaviorally in Part 2 (test_15 / test_16).
  grep -Eq 'case[[:space:]]+"\$engine"[[:space:]]+in' "$DAEMON_SH" \
    || smoke_fail "safety-floor sweep no longer uses an engine case gate (#2007)"
  grep -Eq 'claude\|codex\)' "$DAEMON_SH" \
    || smoke_fail "safety-floor engine gate does not admit claude|codex (#2007)"
  # The detector must be dispatched by engine so codex/claude signatures cannot
  # cross-match.
  grep -q 'detect-prompt --engine "\$engine"' "$DAEMON_SH" \
    || smoke_fail "safety-floor does not pass --engine to the detector (#2007)"
}

# shellcheck disable=SC2329
test_07_mid_render_no_stable_key() {
  # Active output / mid-render must NOT detect (no settled modal).
  local MIDRENDER="Quick safety check:
Yes, I trust this folder
✻ Crunching… (esc to interrupt · 1840 tokens)"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "$MIDRENDER")")" \
    "mid-render / active output does NOT detect a stable modal"
}

# shellcheck disable=SC2329
test_10_untrusted_pane_text() {
  # Shell metacharacters + command-looking text + injection instructions must
  # NOT be executed/sourced — the detector only HASHES and matches affordances.
  local EVIL='WARNING: Loading development channels
I am using this for local development
$(touch /tmp/agb-1991-pwned); `rm -rf ~`; echo INJECTED > /tmp/agb-1991-pwned
Enter to confirm · Esc to cancel'
  rm -f /tmp/agb-1991-pwned
  local out
  out="$(detect "$EVIL")"
  smoke_assert_eq "1" "$(prompt_field PROMPT_MATCHED "$out")" \
    "untrusted text still classifies (devchannels)"
  smoke_assert_eq "devchannels" "$(prompt_field PROMPT_KIND "$out")" \
    "untrusted text classified by affordance, not by its injected commands"
  [[ ! -e /tmp/agb-1991-pwned ]] \
    || smoke_fail "untrusted pane text was EXECUTED — injection guard broken"
  # content_hash is present (the escalation prefers hashes/metadata).
  [[ -n "$(prompt_field PROMPT_CONTENT_HASH "$out")" ]] \
    || smoke_fail "content_hash missing — escalation cannot prefer hashes over raw text"
}

# shellcheck disable=SC2329
test_11_coarse_token_compatibility() {
  # The detector is a SIBLING: it must NOT change the coarse single-token
  # classifier bridge_tmux_claude_blocker_state_from_text (callers compare
  # exact tokens). Source it standalone and assert all tokens are unchanged.
  # shellcheck disable=SC1090
  source <(awk '/^bridge_tmux_claude_blocker_state_from_text\(\)/,/^}/' "$TMUX_SH")
  declare -F bridge_tmux_claude_blocker_state_from_text >/dev/null \
    || smoke_fail "coarse classifier missing after source"

  local TRUST="Quick safety check: Do you trust this folder? Yes, I trust this folder"
  local SUMMARY="Resume from summary (recommended)
Resume full session as-is"
  local DEVCH="WARNING: Loading development channels
I am using this for local development"
  smoke_assert_eq "trust" "$(bridge_tmux_claude_blocker_state_from_text "$TRUST")" "coarse trust token unchanged"
  smoke_assert_eq "summary" "$(bridge_tmux_claude_blocker_state_from_text "$SUMMARY")" "coarse summary token unchanged"
  smoke_assert_eq "devchannels" "$(bridge_tmux_claude_blocker_state_from_text "$DEVCH")" "coarse devchannels token unchanged"
  smoke_assert_eq "none" "$(bridge_tmux_claude_blocker_state_from_text "plain text")" "coarse none token unchanged"

  # And the detector's coarse_state field agrees with the coarse classifier for
  # the kinds they share, so dedupe hash folding stays compatible.
  smoke_assert_eq "devchannels" "$(prompt_field PROMPT_COARSE_STATE "$(detect "$DEVCH
Enter to confirm · Esc to cancel")")" "detector coarse_state matches coarse classifier"
}

# shellcheck disable=SC2329
test_12_picker_style_quoted_text_no_match() {
  # codex r1 finding 1: picker-style kinds (trust/summary/devchannels/billing)
  # match verbatim option strings that ALSO appear quoted in prose / scrollback
  # / a review transcript. Without a structured picker tail they must NOT match
  # (else quoted text escalates). y/n + Press-Enter kinds carry their own
  # inherent affordance and still match without the picker tail.
  local QUOTED_DEVCH='A past log noted: WARNING: Loading development channels
and: I am using this for local development
then the agent finished the task and returned to idle.'
  local QUOTED_SUMMARY='The resume picker had: Resume from summary (recommended)
and: Resume full session as-is
but the session already resumed fine an hour ago.'
  local QUOTED_BILLING='The doc says options like: Stop and wait for limit to reset
appear when you hit a limit; nothing is blocked right now.'
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "$QUOTED_DEVCH")")" \
    "quoted devchannels WITHOUT picker tail does NOT match (no escalation on prose)"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "$QUOTED_SUMMARY")")" \
    "quoted summary WITHOUT picker tail does NOT match"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "$QUOTED_BILLING")")" \
    "quoted billing option WITHOUT picker tail does NOT match"
  # With the structured tail, the real picker DOES match (high confidence).
  local REAL_DEVCH='WARNING: Loading development channels
  1. I am using this for local development
Enter to confirm · Esc to cancel'
  smoke_assert_eq "1" "$(prompt_field PROMPT_MATCHED "$(detect "$REAL_DEVCH")")" \
    "real devchannels WITH picker tail matches"
  smoke_assert_eq "high" "$(prompt_field PROMPT_CONFIDENCE "$(detect "$REAL_DEVCH")")" \
    "real devchannels WITH picker tail is high confidence"
  # Inherent-affordance kinds (y/n) still match without the picker tail.
  smoke_assert_eq "1" "$(prompt_field PROMPT_MATCHED "$(detect "Allow Bash command for this session? (y/n)")")" \
    "permission (y/n) matches via inherent affordance, no picker tail needed"
  # codex r3: a known picker (devchannels) whose footer is QUOTED in a transcript
  # with trailing content after it must NOT match — the picker footer must be the
  # LAST non-blank line (a live footer) to count.
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "The boot log showed:
WARNING: Loading development channels
  1. I am using this for local development
Enter to confirm · Esc to cancel
and then the agent proceeded and finished its task.")")" \
    "quoted devchannels footer with trailing transcript text does NOT match (codex r3 last-line anchor)"
}

# shellcheck disable=SC2329
test_13_unknown_interactive_structured_picker() {
  # codex r1 finding 2: a structured picker affordance with NO known signature
  # is an unknown interactive prompt — keep it (low confidence) so the daemon's
  # longer unknown-prompt deadline applies, rather than dropping a real modal.
  local UNKNOWN_PICKER='Choose a deployment target:
  1. Production
  2. Staging
  3. Cancel
Enter to confirm · Esc to cancel'
  local out; out="$(detect "$UNKNOWN_PICKER")"
  smoke_assert_eq "1" "$(prompt_field PROMPT_MATCHED "$out")" \
    "structured unknown picker matches (does not silently drop a real modal)"
  smoke_assert_eq "unknown_interactive" "$(prompt_field PROMPT_KIND "$out")" \
    "structured unknown picker → unknown_interactive"
  smoke_assert_eq "low" "$(prompt_field PROMPT_CONFIDENCE "$out")" \
    "unknown_interactive is low confidence (daemon applies the longer deadline)"
  # A numbered list WITHOUT a picker tail is still not an unknown modal.
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "Plan:
  1. a
  2. b
  3. c")")" "numbered list without affordance is NOT an unknown modal"

  # codex r2: the unknown gate is STRICT (picker tail + >=2 numbered option
  # rows). Loose prose affordances must NOT mint an unknown escalation.
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "Docs: Press Enter to continue after reading the output.")")" \
    "benign 'Press Enter to continue' prose does NOT match as unknown (codex r2)"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "The tool sometimes asks confirm (y/n) but nothing is blocked now.")")" \
    "stray '(y/n)' in prose does NOT match as unknown (codex r2)"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "Proceed?
  1. Yes
Enter to confirm · Esc to cancel")")" \
    "picker tail with only ONE option row does NOT match (needs >=2 rows, codex r2)"

  # codex r3: a transcript that QUOTES a past picker (option rows + the confirm
  # tail) but has since returned to the ready prompt (a BARE caret line) must
  # NOT match — the bare prompt caret is the idle input box, not a picker
  # selection row (a live picker renders its caret ON an option).
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "earlier the picker showed:
  1. Production
  2. Staging
Enter to confirm · Esc to cancel
(the agent chose one and finished)
❯ ")")" \
    "quoted-picker transcript followed by a bare ready caret does NOT match (codex r3)"
  # The live picker (caret ON an option) is still detected.
  smoke_assert_eq "1" "$(prompt_field PROMPT_MATCHED "$(detect "Choose target:
❯ 1. Production
  2. Staging
Enter to confirm · Esc to cancel")")" \
    "live picker (caret on an option row) still matches"

  # codex r3 (last-line anchor): the picker footer must be the LAST non-blank
  # line. A transcript or log that quotes a picker footer with trailing content
  # after it must NOT match, even with >=2 option rows present.
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "Review transcript, not a live modal:
The old pane output included this quoted chooser footer:
  1. x
  2. y
Enter to confirm · Esc to cancel
End transcript; the current agent is not blocked on a modal.")")" \
    "transcript quoting a picker footer (trailing text after) does NOT match (codex r3)"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "INFO begin unrelated log excerpt
INFO numbered items from docs:
  1. alpha
  2. beta
Enter to confirm · Esc to cancel
INFO job completed; nothing is waiting for input")")" \
    "log excerpt with a quoted picker footer mid-stream does NOT match (codex r3)"
}

# shellcheck disable=SC2329
test_14_report_fence_breakout_guard() {
  # codex r1 finding 4: a pane line containing a triple-backtick must NOT break
  # out of the report's code block. We render the excerpt as an INDENTED block
  # (no closing delimiter to spoof). Drive the real report writer with a
  # malicious excerpt and assert the injected prose stays inside the indented
  # block (every excerpt line is 4-space-prefixed) and no bare ``` line exists
  # that could close a fence.
  local report="$SMOKE_TMP_ROOT/fence-test.md"
  local EVIL='line one
```
## INJECTED HEADING (should stay code)
echo PWNED
```
line five'
  bridge_write_blocked_prompt_report "$report" "agent-x" "sess" "devchannels" \
    "deadbeef" "high" "100" "200" "$EVIL"
  smoke_assert_file_exists "$report" "report written"
  # The injected heading must be indented (inside the code block), not a bare
  # markdown heading that renders as trusted prose.
  grep -q '^    ## INJECTED HEADING' "$report" \
    || smoke_fail "injected heading not indented — fence breakout possible"
  smoke_assert_not_contains "$(grep -n '^## INJECTED' "$report" || true)" "INJECTED" \
    "no UNINDENTED injected heading in the report (breakout blocked)"
  # The backtick lines from the excerpt must be indented too, not bare fences.
  grep -q '^    ```' "$report" \
    || smoke_fail "excerpt backtick line not indented — could close a fence"
}

# ---------------------------------------------------------------------------
# Issue #2007: Codex detector cases (detect-only). Numbering/prefix-independent
# hook-trust match, quoted/logged negative, unknown low-confidence modal, and
# the back-compat guarantee that the Codex signatures NEVER match on the Claude
# path (no #1991 regression).
# ---------------------------------------------------------------------------

# The verified 0.140 hook-trust prompt in its two rendered variants. Numbered
# (10-hook top-level menu) and unnumbered `›` selector (1-hook). The 6 signature
# strings are byte-identical across both; only the option-row prefix differs.
CODEX_HOOK_TRUST_NUMBERED='Hooks need review
2 hooks are new or changed since you last reviewed them.
1. Review hooks
2. Trust all and continue
3. Continue without trusting
Press enter to confirm or esc to go back'

CODEX_HOOK_TRUST_UNNUMBERED='Hooks need review
1 hook is new or changed since you last reviewed it.
›  Review hooks
   Trust all and continue
   Continue without trusting
Press enter to confirm or esc to go back'

# shellcheck disable=SC2329
test_15_codex_hook_trust_numbering_independent() {
  # Both the numbered and the unnumbered-prefix variant must match as a
  # high-confidence codex_hook_trust prompt (design Addendum: strip N./› before
  # matching — here the substring signatures are inherently prefix-independent).
  local num unum
  num="$(detect_codex "$CODEX_HOOK_TRUST_NUMBERED")"
  unum="$(detect_codex "$CODEX_HOOK_TRUST_UNNUMBERED")"
  smoke_assert_eq "1" "$(prompt_field PROMPT_MATCHED "$num")" \
    "codex hook-trust (numbered menu) detects"
  smoke_assert_eq "codex_hook_trust" "$(prompt_field PROMPT_KIND "$num")" \
    "codex hook-trust (numbered) classified as codex_hook_trust"
  smoke_assert_eq "high" "$(prompt_field PROMPT_CONFIDENCE "$num")" \
    "codex hook-trust (numbered) is high confidence"
  smoke_assert_eq "1" "$(prompt_field PROMPT_MATCHED "$unum")" \
    "codex hook-trust (unnumbered › prefix) detects — numbering-independent"
  smoke_assert_eq "codex_hook_trust" "$(prompt_field PROMPT_KIND "$unum")" \
    "codex hook-trust (unnumbered) classified the same as numbered"
  # content_hash present so escalation can prefer hashes over raw pane text.
  [[ -n "$(prompt_field PROMPT_CONTENT_HASH "$num")" ]] \
    || smoke_fail "codex hook-trust content_hash missing"
}

# shellcheck disable=SC2329
test_16_codex_quoted_logged_prompt_no_match() {
  # A transcript/log that QUOTES the hook-trust prompt with trailing content
  # after the footer must NOT match — the confirm footer must be the LAST
  # non-blank line (live footer), mirroring the Claude last-line anchor.
  local QUOTED="The startup log recorded:
$CODEX_HOOK_TRUST_NUMBERED
and then the agent trusted the hooks and continued its task."
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect_codex "$QUOTED")")" \
    "quoted codex hook-trust with trailing text does NOT match (last-line anchor)"
  # A bare ready caret after the footer (agent returned to the composer) → no match.
  local RESOLVED="$CODEX_HOOK_TRUST_NUMBERED
›"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect_codex "$RESOLVED")")" \
    "codex hook-trust followed by a bare ready caret does NOT match (resolved)"
  # Active mid-render output after the footer → no match.
  local MIDRENDER="$CODEX_HOOK_TRUST_NUMBERED
✻ Working… (esc to interrupt · 200 tokens)"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect_codex "$MIDRENDER")")" \
    "codex active-output tail does NOT match a settled modal"
}

# shellcheck disable=SC2329
test_17_codex_unknown_modal_low_confidence() {
  # A Codex modal with the exact confirm footer as the live last line plus >=2
  # numbered/selector option rows, but NO hook-trust signature → low-confidence
  # codex_unknown_interactive (longer unknown deadline applies).
  local UNKNOWN="Choose how to proceed:
1. Apply the patch
2. Skip for now
Press enter to confirm or esc to go back"
  local out; out="$(detect_codex "$UNKNOWN")"
  smoke_assert_eq "1" "$(prompt_field PROMPT_MATCHED "$out")" \
    "structured unknown codex modal detects"
  smoke_assert_eq "codex_unknown_interactive" "$(prompt_field PROMPT_KIND "$out")" \
    "unknown codex modal classified as codex_unknown_interactive"
  smoke_assert_eq "low" "$(prompt_field PROMPT_CONFIDENCE "$out")" \
    "unknown codex modal is low confidence (longer deadline)"
  # Benign prose with the footer text but no option rows → no match.
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect_codex \
    "All done. The prompt 'Press enter to confirm or esc to go back' is gone.
Idle now.")")" \
    "benign prose mentioning the footer does NOT match (footer not last line)"
  # Footer as last line but only ONE option row → no match (needs >=2).
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect_codex \
    "Continue?
1. Yes
Press enter to confirm or esc to go back")")" \
    "single option row does NOT match unknown codex modal (needs >=2 rows)"
}

# shellcheck disable=SC2329
test_18_codex_signatures_inert_on_claude_path() {
  # No #1991 regression: the Codex hook-trust prompt must NOT match the Claude
  # detector (default engine), and a Claude picker must NOT match the Codex
  # detector. The two signature sets are disjoint.
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect "$CODEX_HOOK_TRUST_NUMBERED")")" \
    "codex hook-trust does NOT match the Claude detector (default engine)"
  local CLAUDE_DEVCH='WARNING: Loading development channels
  1. I am using this for local development
Enter to confirm · Esc to cancel'
  smoke_assert_eq "1" "$(prompt_field PROMPT_MATCHED "$(detect "$CLAUDE_DEVCH")")" \
    "claude devchannels still matches the Claude detector (no regression)"
  smoke_assert_eq "0" "$(prompt_field PROMPT_MATCHED "$(detect_codex "$CLAUDE_DEVCH")")" \
    "claude devchannels does NOT match the Codex detector (disjoint signatures)"
}

# ===========================================================================
# Part 2: daemon all-pane sweep + INDEPENDENT escalation. We source the real
# safety-floor functions from bridge-daemon.sh (via bridge-lib.sh for the
# helper graph), STUB bridge-notify.sh + the tmux capture/session helpers, and
# drive process_blocked_prompt_safety_floor through ticks.
# ===========================================================================

# A stub SCRIPT_DIR holding the real lib + a STUB bridge-notify.sh + stub
# bridge-stall.py shim that just delegates to the real one. The stub notify
# records every call to a log so we can assert the daemon called it directly.
STUB_DIR="$SMOKE_TMP_ROOT/stub-bin"
mkdir -p "$STUB_DIR"
NOTIFY_LOG="$SMOKE_TMP_ROOT/notify-calls.log"
: >"$NOTIFY_LOG"

# Stubbed bridge-notify.sh send: append the args to NOTIFY_LOG and exit 0. NO
# network. This is the proof the daemon reaches the transport with no agent.
cat >"$STUB_DIR/bridge-notify.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$NOTIFY_LOG"
exit 0
STUB
chmod +x "$STUB_DIR/bridge-notify.sh"
# The real classifier (the sweep invokes \$SCRIPT_DIR/bridge-stall.py).
cp "$STALL_PY" "$STUB_DIR/bridge-stall.py"
# bridge-daemon-helpers.py is used for ISO formatting in the report writer.
if [[ -f "$REPO_ROOT/bridge-daemon-helpers.py" ]]; then
  cp "$REPO_ROOT/bridge-daemon-helpers.py" "$STUB_DIR/bridge-daemon-helpers.py"
fi

# Load the helper graph, then the safety-floor functions from the daemon.
# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-lib.sh"
# Source each #1991 safety-floor function via a bounded awk extraction by name
# (the 1181 smoke uses the same single-function source pattern). Each function
# is self-contained shell.
for _fn in bridge_operator_notify_resolve bridge_operator_notify_send \
  bridge_safety_floor_state_file bridge_safety_floor_operator_notify_marker_file \
  bridge_safety_floor_set_operator_notify_status bridge_clear_safety_floor_state \
  bridge_note_safety_floor_state bridge_write_blocked_prompt_report \
  process_blocked_prompt_safety_floor; do
  # shellcheck disable=SC1090
  source <(awk -v fn="^${_fn}\\\\(\\\\) \\\\{" '$0 ~ fn {f=1} f {print} f && /^}/ {exit}' "$DAEMON_SH")
done

declare -F process_blocked_prompt_safety_floor >/dev/null \
  || smoke_fail "process_blocked_prompt_safety_floor not defined after source"
declare -F bridge_operator_notify_send >/dev/null \
  || smoke_fail "bridge_operator_notify_send not defined after source"

# Point the sweep's $SCRIPT_DIR at the stub dir so bridge-notify.sh + the
# classifier resolve to our stubs.
SCRIPT_DIR="$STUB_DIR"

# --- tmux stubs: the sweep calls bridge_capture_recent + bridge_tmux_session_exists.
# We override them so a fixture pane can be set per agent. The capture content
# is read from a per-session file.
declare -A PANE_FIXTURE=()
# shellcheck disable=SC2329
bridge_capture_recent() {
  local session="$1"
  printf '%s' "${PANE_FIXTURE[$session]:-}"
}
# shellcheck disable=SC2329
bridge_tmux_session_exists() {
  local session="$1"
  [[ -n "${PANE_FIXTURE[$session]+x}" ]]
}
# bridge_with_timeout wraps the python detector via timeout(1); keep the real
# one (it execs python3 from the stub dir). bridge_agent_exists / notify
# helpers come from the real lib graph but the roster is empty here, so we set
# the admin + operator-notify env explicitly per case.

# Build a one-row summary TSV line:
#   agent queued claimed blocked active idle last_seen last_nudge session engine workdir
# shellcheck disable=SC2329
summary_row() {
  local agent="$1" session="$2" engine="${3:-claude}"
  printf '%s\t0\t0\t0\t1\t300\t0\t0\t%s\t%s\t/tmp/wd\n' "$agent" "$session" "$engine"
}

# Helper: clear cadence + notify log between cases for isolation.
# shellcheck disable=SC2329
reset_floor_state() {
  rm -rf "$BRIDGE_STATE_DIR/safety-floor" "$BRIDGE_STATE_DIR/daemon-pass-cadence" 2>/dev/null || true
  : >"$NOTIFY_LOG"
  PANE_FIXTURE=()
}

DEVCH_PANE='WARNING: Loading development channels
  1. I am using this for local development
  2. Cancel
Enter to confirm · Esc to cancel'

# Tick the sweep N times (each tick is a fresh call; the function persists state
# via files under BRIDGE_STATE_DIR). To pass the deadline without sleeping, we
# rewind the recorded first_seen_ts in the state file between the stable-tick
# arming and the escalation tick.
# shellcheck disable=SC2329
floor_tick() {
  process_blocked_prompt_safety_floor "$1" >/dev/null 2>&1 || true
}

# shellcheck disable=SC2329
age_first_seen() {
  # Rewind first_seen by $2 seconds for $1's state file so the deadline trips
  # without a real wait.
  local agent="$1" back="$2" sf
  sf="$(bridge_safety_floor_state_file "$agent")"
  [[ -f "$sf" ]] || return 0
  local now first new
  now="$(date +%s)"
  # shellcheck disable=SC1090
  ( source "$sf"; printf '%s' "${SAFETY_FLOOR_FIRST_SEEN_TS:-$now}" ) >/dev/null
  first="$(awk -F= '/^SAFETY_FLOOR_FIRST_SEEN_TS=/{gsub(/[^0-9]/,"",$2); print $2}' "$sf")"
  [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
  new=$(( first - back ))
  # Rewrite the first_seen line in place.
  awk -v new="$new" 'BEGIN{OFS=""} /^SAFETY_FLOOR_FIRST_SEEN_TS=/{print "SAFETY_FLOOR_FIRST_SEEN_TS=", new; next} {print}' "$sf" >"$sf.tmp" && mv "$sf.tmp" "$sf"
}

# shellcheck disable=SC2329
notify_count() {
  # Count non-empty lines in the notify call log. `grep -c` prints 0 and exits
  # 1 on no match, so swallow the exit without printing a second 0.
  local n
  n="$(grep -c . "$NOTIFY_LOG" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# shellcheck disable=SC2329
test_01_idle_blocked_no_work_detects_and_escalates() {
  reset_floor_state
  export BRIDGE_ADMIN_AGENT_ID=""
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord"
  export BRIDGE_OPERATOR_NOTIFY_TARGET="123456789"
  export BRIDGE_OPERATOR_NOTIFY_ACCOUNT="default"
  PANE_FIXTURE=([worker-claude]="$DEVCH_PANE")
  local row; row="$(summary_row worker-claude worker-claude claude)"

  # Tick 1: detect (stable_ticks=1) — no escalation yet (needs 2 ticks).
  floor_tick "$row"
  smoke_assert_eq "0" "$(notify_count)" "tick1: detect only, no escalation before 2-tick stability"

  # Tick 2: stable_ticks=2 — armed, but within deadline → no notify yet.
  floor_tick "$row"
  smoke_assert_eq "0" "$(notify_count)" "tick2: armed but within 90s deadline → no escalation"

  # Age past the 90s deadline and tick: escalate via DIRECT operator notify.
  age_first_seen worker-claude 120
  floor_tick "$row"
  smoke_assert_eq "1" "$(notify_count)" "tick3: deadline passed → exactly one DIRECT operator notify"
  smoke_assert_contains "$(cat "$NOTIFY_LOG")" "--kind discord" "daemon called external transport with --kind"
  smoke_assert_contains "$(cat "$NOTIFY_LOG")" "--target 123456789" "daemon called external transport with --target"
  smoke_assert_contains "$(cat "$NOTIFY_LOG")" "worker-claude blocked on claude devchannels" "notify names the agent + engine + prompt kind"

  # A report was written FIRST under shared/blocked-prompts.
  local reports; reports="$(find "$BRIDGE_SHARED_DIR/blocked-prompts" -name '*-worker-claude-claude-devchannels-*.md' 2>/dev/null | head -1)"
  [[ -n "$reports" ]] || smoke_fail "escalation report not written under shared/blocked-prompts"
  smoke_assert_contains "$(cat "$reports")" "UNTRUSTED" "report flags pane text as untrusted"
}

# shellcheck disable=SC2329
test_02_auto_accept_succeeds_no_escalation() {
  reset_floor_state
  export BRIDGE_ADMIN_AGENT_ID=""
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord"
  export BRIDGE_OPERATOR_NOTIFY_TARGET="123456789"
  PANE_FIXTURE=([w2]="$DEVCH_PANE")
  local row; row="$(summary_row w2 w2 claude)"
  floor_tick "$row"   # detect
  floor_tick "$row"   # armed
  # Auto-accept clears the prompt before the deadline: pane no longer blocked.
  PANE_FIXTURE=([w2]='❯ waiting for your input')
  age_first_seen w2 120
  floor_tick "$row"
  smoke_assert_eq "0" "$(notify_count)" "cleared prompt before deadline → NO escalation"
  [[ ! -f "$(bridge_safety_floor_state_file w2)" ]] \
    || smoke_fail "state not cleared after prompt resolved"
}

# shellcheck disable=SC2329
test_03_admin_unavailable_operator_still_notified() {
  reset_floor_state
  # Non-admin agent blocked; admin session missing/unavailable; explicit
  # operator target configured. The DIRECT external notify must still fire.
  export BRIDGE_ADMIN_AGENT_ID="ghost-admin"   # not in roster → bridge_agent_exists false
  export BRIDGE_OPERATOR_NOTIFY_KIND="telegram"
  export BRIDGE_OPERATOR_NOTIFY_TARGET="-100999"
  PANE_FIXTURE=([w3]="$DEVCH_PANE")
  local row; row="$(summary_row w3 w3 claude)"
  floor_tick "$row"; floor_tick "$row"; age_first_seen w3 120; floor_tick "$row"
  smoke_assert_eq "1" "$(notify_count)" "operator notified independent of admin availability"
  smoke_assert_contains "$(cat "$NOTIFY_LOG")" "--kind telegram" "notify used the explicit operator transport"
  # No admin task is the proof — operator notify happened with no live admin.
  smoke_assert_contains "$(cat "$NOTIFY_LOG")" "--target -100999" "notify reached the configured operator target"
}

# shellcheck disable=SC2329
test_04_self_picker_bootstrap_direct_notify() {
  reset_floor_state
  # The admin agent itself shows a launch picker. It cannot read a task
  # assigned to itself → must DIRECT-notify the operator.
  export BRIDGE_ADMIN_AGENT_ID="patch"
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord"
  export BRIDGE_OPERATOR_NOTIFY_TARGET="555"
  PANE_FIXTURE=([patch]="$DEVCH_PANE")
  local row; row="$(summary_row patch patch claude)"
  floor_tick "$row"; floor_tick "$row"; age_first_seen patch 120; floor_tick "$row"
  smoke_assert_eq "1" "$(notify_count)" "self-picker admin → DIRECT operator notify (not a self-task)"
  smoke_assert_contains "$(cat "$NOTIFY_LOG")" "patch blocked on claude devchannels" "self-picker notify names the admin"
}

# shellcheck disable=SC2329
test_08_dedupe_no_storm_then_cooldown_refire() {
  reset_floor_state
  export BRIDGE_ADMIN_AGENT_ID=""
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord"
  export BRIDGE_OPERATOR_NOTIFY_TARGET="777"
  export BRIDGE_BLOCKED_PROMPT_REFIRE_SECONDS=1800
  PANE_FIXTURE=([w8]="$DEVCH_PANE")
  local row; row="$(summary_row w8 w8 claude)"
  floor_tick "$row"; floor_tick "$row"; age_first_seen w8 120; floor_tick "$row"
  smoke_assert_eq "1" "$(notify_count)" "first escalation fires once"
  # Several more ticks with the SAME key: no storm (within cooldown).
  floor_tick "$row"; floor_tick "$row"; floor_tick "$row"
  smoke_assert_eq "1" "$(notify_count)" "same key within cooldown → no refire storm"
  # Age the refire_ts past the cooldown → visible refire (still blocked). The
  # cooldown gates on refire_ts (last ATTEMPT), NOT notify_ts (codex r1 #3).
  local sf; sf="$(bridge_safety_floor_state_file w8)"
  awk 'BEGIN{OFS=""} /^SAFETY_FLOOR_REFIRE_TS=/{print "SAFETY_FLOOR_REFIRE_TS=1"; next} {print}' "$sf" >"$sf.tmp" && mv "$sf.tmp" "$sf"
  floor_tick "$row"
  smoke_assert_eq "2" "$(notify_count)" "same key after cooldown → visible refire (still blocked, #1986/#1973)"
  # Change the prompt (new content hash) → new key/latch, fresh deadline.
  PANE_FIXTURE=([w8]='Quick safety check:
  1. Yes, I trust this folder
  2. No
Enter to confirm · Esc to cancel')
  floor_tick "$row"   # re-latch (stable=1)
  smoke_assert_eq "2" "$(notify_count)" "content-hash change re-latches with fresh deadline (no immediate refire)"
}

# shellcheck disable=SC2329
test_09_missing_operator_notify_config_audit_no_guarantee() {
  reset_floor_state
  # No explicit operator target AND no admin notify fallback → the daemon must
  # NOT claim the independent guarantee. operator_notify=missing surfaced.
  export BRIDGE_ADMIN_AGENT_ID=""
  unset BRIDGE_OPERATOR_NOTIFY_KIND BRIDGE_OPERATOR_NOTIFY_TARGET BRIDGE_OPERATOR_NOTIFY_ACCOUNT
  PANE_FIXTURE=([w9]="$DEVCH_PANE")
  local row; row="$(summary_row w9 w9 claude)"
  floor_tick "$row"; floor_tick "$row"; age_first_seen w9 120; floor_tick "$row"
  smoke_assert_eq "0" "$(notify_count)" "no operator target → NO external notify (guarantee not active)"
  # The status marker surfaces operator_notify=missing loudly.
  local marker; marker="$(bridge_safety_floor_operator_notify_marker_file)"
  smoke_assert_file_exists "$marker" "operator-notify status marker written"
  smoke_assert_contains "$(cat "$marker")" "operator_notify=missing" "status marker surfaces operator_notify=missing"
  # Resolve helper returns non-zero (missing) deterministically.
  if bridge_operator_notify_resolve >/dev/null 2>&1; then
    smoke_fail "operator_notify_resolve must FAIL when no target configured"
  fi
  # codex r1 finding 3: with no operator target, the missing-config escalation
  # must still respect the 30min refire cooldown — it must NOT re-write the
  # report/audit/queue every 15s tick. After the first escalation, refire_ts is
  # latched; subsequent ticks within cooldown produce no new report file.
  local before_reports after_reports
  before_reports="$(find "$BRIDGE_SHARED_DIR/blocked-prompts" -name '*-w9-*.md' 2>/dev/null | wc -l | tr -d ' ')"
  floor_tick "$row"; floor_tick "$row"; floor_tick "$row"
  after_reports="$(find "$BRIDGE_SHARED_DIR/blocked-prompts" -name '*-w9-*.md' 2>/dev/null | wc -l | tr -d ' ')"
  smoke_assert_eq "$before_reports" "$after_reports" \
    "missing-operator escalation respects cooldown (no report-storm every tick, codex r1 #3)"
}

# A live Codex hook-trust pane (numbered top-level menu). Footer is the literal
# last line — a live modal, not a quoted transcript.
CODEX_PANE='Hooks need review
2 hooks are new or changed since you last reviewed them.
1. Review hooks
2. Trust all and continue
3. Continue without trusting
Press enter to confirm or esc to go back'

# shellcheck disable=SC2329
test_19_daemon_routes_codex_via_same_floor() {
  # Issue #2007: a Codex pane blocked on a hook-trust prompt routes through the
  # SAME safety floor and escalates via the SAME direct operator notify — no
  # second floor, no keys sent.
  reset_floor_state
  export BRIDGE_ADMIN_AGENT_ID=""
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord"
  export BRIDGE_OPERATOR_NOTIFY_TARGET="222"
  PANE_FIXTURE=([worker-codex]="$CODEX_PANE")
  local row; row="$(summary_row worker-codex worker-codex codex)"
  floor_tick "$row"   # detect (stable=1)
  smoke_assert_eq "0" "$(notify_count)" "codex tick1: detect only, no escalation before 2-tick stability"
  floor_tick "$row"   # armed (stable=2), within deadline
  smoke_assert_eq "0" "$(notify_count)" "codex tick2: armed but within 90s deadline → no escalation"
  age_first_seen worker-codex 120
  floor_tick "$row"
  smoke_assert_eq "1" "$(notify_count)" "codex tick3: deadline passed → exactly one DIRECT operator notify"
  smoke_assert_contains "$(cat "$NOTIFY_LOG")" "--kind discord" "codex floor used the external transport"
  smoke_assert_contains "$(cat "$NOTIFY_LOG")" "worker-codex blocked on codex codex_hook_trust" \
    "codex notify names the engine + codex_hook_trust kind"
  # The report carries the engine in both its path and its body.
  local reports; reports="$(find "$BRIDGE_SHARED_DIR/blocked-prompts" -name '*-worker-codex-codex-codex_hook_trust-*.md' 2>/dev/null | head -1)"
  [[ -n "$reports" ]] || smoke_fail "codex escalation report (engine in path) not written"
  smoke_assert_contains "$(cat "$reports")" "- engine: codex" "codex report names the engine"
}

# shellcheck disable=SC2329
test_20_daemon_skips_other_engines() {
  # An engine that is neither claude nor codex (e.g. a future/unknown runtime)
  # must be skipped entirely — no detect, no escalation. Even with a pane that
  # WOULD match the codex detector, a gemini-engine row produces no notify.
  reset_floor_state
  export BRIDGE_ADMIN_AGENT_ID=""
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord"
  export BRIDGE_OPERATOR_NOTIFY_TARGET="333"
  PANE_FIXTURE=([worker-other]="$CODEX_PANE")
  local row; row="$(summary_row worker-other worker-other gemini)"
  floor_tick "$row"; floor_tick "$row"; age_first_seen worker-other 120 || true; floor_tick "$row"
  smoke_assert_eq "0" "$(notify_count)" "non-claude/codex engine is skipped (no escalation)"
  [[ ! -f "$(bridge_safety_floor_state_file worker-other)" ]] \
    || smoke_fail "non-claude/codex engine left safety-floor state (should be skipped before detect)"
}

# ===========================================================================
# Part 3: mutation tests — the key teeth are non-vacuous.
# ===========================================================================

# shellcheck disable=SC2329
test_mutation_idle_sweep_removed_no_detect() {
  # If the all-pane sweep were gone, an idle no-work pane would never be swept.
  # Proxy: confirm the daemon main loop actually wires the sweep on the idle
  # path (NOT gated behind claimed>0). The function exists AND is called from
  # cmd_sync_cycle without a claimed/queued precondition.
  grep -q 'process_blocked_prompt_safety_floor "\$summary_output"' "$DAEMON_SH" \
    || smoke_fail "MUTATION GUARD: sweep not wired into the daemon loop"
  # The sweep itself must NOT require claimed/queued > 0 (the blind-spot fix).
  local body
  body="$(awk '/^process_blocked_prompt_safety_floor\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DAEMON_SH")"
  smoke_assert_not_contains "$body" 'claimed > 0' "MUTATION GUARD: sweep must not gate on claimed>0 (idle blind spot)"
}

# shellcheck disable=SC2329
test_mutation_escalation_independence() {
  # The guarantee is a DIRECT external transport call, not an admin task. The
  # notify helper must call bridge-notify.sh send with explicit --kind/--target.
  local body
  body="$(awk '/^bridge_operator_notify_send\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DAEMON_SH")"
  smoke_assert_contains "$body" 'bridge-notify.sh' "MUTATION GUARD: operator notify uses the external transport directly"
  smoke_assert_contains "$body" '--kind' "MUTATION GUARD: operator notify passes an explicit --kind"
  smoke_assert_contains "$body" '--target' "MUTATION GUARD: operator notify passes an explicit --target"
  # The floor is observe-only: the sweep must never send keys.
  local sweep
  sweep="$(awk '/^process_blocked_prompt_safety_floor\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DAEMON_SH")"
  smoke_assert_not_contains "$sweep" "bridge_tmux_send_and_submit" "OBSERVE-ONLY: sweep must not submit keys"
  smoke_assert_not_contains "$sweep" "send-keys" "OBSERVE-ONLY: sweep must not send tmux keys"
}

# --- run -------------------------------------------------------------------
smoke_run "05: non-picker false-positive guards (numbered list / docs / ready)" test_05_non_picker_false_positives
smoke_run "06: engine gate admits claude|codex, dispatches by --engine (#2007)" test_06_engine_gate_claude_and_codex
smoke_run "07: mid-render / active output → no stable modal" test_07_mid_render_no_stable_key
smoke_run "10: untrusted pane text → hashes only, no execution" test_10_untrusted_pane_text
smoke_run "11: coarse-token compatibility (classifier unchanged)" test_11_coarse_token_compatibility
smoke_run "12: picker-style quoted text → no match (codex r1 #1)" test_12_picker_style_quoted_text_no_match
smoke_run "13: structured unknown picker → unknown_interactive low (codex r1 #2)" test_13_unknown_interactive_structured_picker
smoke_run "14: report fence-breakout guard (codex r1 #4)" test_14_report_fence_breakout_guard
smoke_run "15: codex hook-trust numbering/prefix-independent (#2007)" test_15_codex_hook_trust_numbering_independent
smoke_run "16: codex quoted/logged prompt → no match (#2007 last-line anchor)" test_16_codex_quoted_logged_prompt_no_match
smoke_run "17: codex unknown modal → low confidence (#2007)" test_17_codex_unknown_modal_low_confidence
smoke_run "18: codex signatures inert on Claude path (no #1991 regression)" test_18_codex_signatures_inert_on_claude_path
smoke_run "01: idle blocked no-work pane → detect + DIRECT escalate" test_01_idle_blocked_no_work_detects_and_escalates
smoke_run "02: auto-accept succeeds → no escalation" test_02_auto_accept_succeeds_no_escalation
smoke_run "03: admin unavailable → operator still notified (independent)" test_03_admin_unavailable_operator_still_notified
smoke_run "04: self-picker bootstrap → direct operator notify" test_04_self_picker_bootstrap_direct_notify
smoke_run "08: dedupe/no-storm then cooldown refire + re-latch" test_08_dedupe_no_storm_then_cooldown_refire
smoke_run "09: missing operator-notify config → audit operator_notify=missing, no guarantee" test_09_missing_operator_notify_config_audit_no_guarantee
smoke_run "19: daemon routes codex via the SAME floor → direct escalate (#2007)" test_19_daemon_routes_codex_via_same_floor
smoke_run "20: daemon skips non-claude/codex engines (#2007)" test_20_daemon_skips_other_engines
smoke_run "MUTATION: idle sweep removed → no detect (non-vacuous)" test_mutation_idle_sweep_removed_no_detect
smoke_run "MUTATION: escalation independence (direct transport, observe-only)" test_mutation_escalation_independence

smoke_log "all #1991 blocked-prompt safety-floor detect/escalate/independence/no-storm/observe-only checks pass"
exit 0
