#!/usr/bin/env bash
# Regression coverage for Issue 2 (v0.11.0) — resume-resolver quarantine and
# forget-session integration. Verifies that:
#
#   1. bridge_run_quarantine_rejected_resume only fires on a real Claude
#      `--resume <stale-id>` rejection, NOT on unrelated short-duration
#      failures (auth, plugin, stdin contract, etc).
#   2. The launch-cmd fallback fires only when stderr is empty or
#      whitespace-only (the live-symptom shape where Claude's TUI
#      alt-screen swallows the rejection message before exit).
#   3. forget-session clears the per-agent `resume-quarantine.json` even
#      when the persisted session id is already empty (changed=no path).
#   4. forget-session on an active agent preserves the quarantine and
#      warns the operator to retry after `agent stop`.
#
# Runs entirely in an isolated $TMP so it never reads or writes the
# operator's live bridge state.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-resume-quarantine-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------------------
# Section A — bridge_run_quarantine_rejected_resume gating
# ----------------------------------------------------------------------------
# Extract just the helper out of bridge-run.sh; stub its deps so we can
# drive it with controlled exit codes / durations / stderr slices.
HOOK_TMP="$TMP/hook.sh"
awk '
  /^bridge_run_quarantine_rejected_resume\(\) \{/ { copy = 1 }
  copy { print }
  copy && /^\}$/ { copy = 0; print ""; exit }
' "$ROOT_DIR/bridge-run.sh" >"$HOOK_TMP"

# State captured by the stubs so each case can assert what the helper did.
QUARANTINE_RECORDED=""
ARCHIVE_CALLED=""
LOG_LINES=""
# Issue #2106: ids the (mocked) quarantine store actually holds. Each case that
# expects a genuine record appends here too; the foreign-refusal case (A9)
# leaves it EMPTY while still returning rc=0 from add — exactly the
# bridge_agent_resume_quarantine_add foreign-guard shape (rc=0, recorded
# nothing). QUARANTINE_IDS_OVERRIDE, when set, forces the ids reader's output
# so a case can decouple "add was called" from "id is actually quarantined".
QUARANTINE_IDS=""
QUARANTINE_IDS_OVERRIDE="__unset__"

# Stubs that mimic the helper's collaborators.
ENGINE="claude"
AGENT="testagent"
bridge_agent_resume_quarantine_add() {
  # args: agent session_id reason
  QUARANTINE_RECORDED+="$1|$2|$3"$'\n'
  # Default: a successful record makes the id observable to the ids reader.
  # A9 overrides QUARANTINE_IDS_OVERRIDE to simulate a foreign-guard refusal
  # (add returns 0 but records nothing).
  if [[ "$QUARANTINE_IDS_OVERRIDE" == "__unset__" ]]; then
    QUARANTINE_IDS="${QUARANTINE_IDS:+$QUARANTINE_IDS,}$2"
  fi
  return 0
}
# Issue #2106: the helper now re-reads the quarantine list to confirm the id was
# genuinely recorded before logging "subsequent launches will skip" — so the
# false-reassurance log can no longer fire on a foreign-guard refusal.
bridge_agent_resume_quarantine_ids() {
  if [[ "$QUARANTINE_IDS_OVERRIDE" != "__unset__" ]]; then
    printf '%s' "$QUARANTINE_IDS_OVERRIDE"
    return 0
  fi
  printf '%s' "$QUARANTINE_IDS"
}
bridge_agent_resume_quarantine_archive_transcript() {
  ARCHIVE_CALLED+="$1|$2"$'\n'
  return 0
}
bridge_resume_session_id_valid() {
  [[ -n "${1:-}" ]] || return 1
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  return 0
}
bridge_audit_log() { return 0; }
log_line() { LOG_LINES+="$*"$'\n'; }

# shellcheck source=/dev/null
source "$HOOK_TMP"

reset_state() {
  QUARANTINE_RECORDED=""; ARCHIVE_CALLED=""; LOG_LINES=""
  QUARANTINE_IDS=""; QUARANTINE_IDS_OVERRIDE="__unset__"
  : >"$TMP/err.log"
}

UUID="11111111-2222-3333-4444-555555555555"
LAUNCH_RESUME="claude --resume $UUID --dangerously-skip-permissions --name testagent"
LAUNCH_FRESH="claude --dangerously-skip-permissions --name testagent"

step "A1: stderr contains 'No conversation found' -> quarantine (source=stderr)"
reset_state
printf 'No conversation found with session ID: %s\n' "$UUID" >"$TMP/err.log"
sz=$(wc -c <"$TMP/err.log")
bridge_run_quarantine_rejected_resume 1 3 "$LAUNCH_RESUME" "$TMP/err.log" 0 "$sz" || true
if printf '%s' "$QUARANTINE_RECORDED" | grep -q "${AGENT}|${UUID}|no-conversation-found"; then
  ok
else
  err "expected quarantine for $UUID; got [$QUARANTINE_RECORDED]"
fi

step "A2: empty stderr + short duration + --resume -> fallback quarantine"
reset_state
: >"$TMP/err.log"
bridge_run_quarantine_rejected_resume 1 3 "$LAUNCH_RESUME" "$TMP/err.log" 0 0 || true
if printf '%s' "$QUARANTINE_RECORDED" | grep -q "${AGENT}|${UUID}|no-conversation-found"; then
  ok
else
  err "expected fallback quarantine; got [$QUARANTINE_RECORDED]"
fi

step "A3 (regression): short --resume + UNRELATED stderr does NOT fallback-quarantine"
reset_state
printf 'Error: Input must be provided either through stdin or as a prompt argument\n' >"$TMP/err.log"
sz=$(wc -c <"$TMP/err.log")
bridge_run_quarantine_rejected_resume 1 3 "$LAUNCH_RESUME" "$TMP/err.log" 0 "$sz" || true
if [[ -z "$QUARANTINE_RECORDED" ]]; then
  ok
else
  err "expected NO quarantine on unrelated stderr; got [$QUARANTINE_RECORDED]"
fi

step "A4: whitespace-only stderr -> treated as empty -> fallback quarantine"
reset_state
printf '   \n\t  \n' >"$TMP/err.log"
sz=$(wc -c <"$TMP/err.log")
bridge_run_quarantine_rejected_resume 1 3 "$LAUNCH_RESUME" "$TMP/err.log" 0 "$sz" || true
if printf '%s' "$QUARANTINE_RECORDED" | grep -q "${AGENT}|${UUID}|no-conversation-found"; then
  ok
else
  err "expected fallback quarantine for whitespace-only stderr; got [$QUARANTINE_RECORDED]"
fi

step "A5: long-running launch (duration > 10s) + empty stderr -> no fallback"
reset_state
: >"$TMP/err.log"
bridge_run_quarantine_rejected_resume 1 60 "$LAUNCH_RESUME" "$TMP/err.log" 0 0 || true
if [[ -z "$QUARANTINE_RECORDED" ]]; then
  ok
else
  err "expected NO quarantine for long-running; got [$QUARANTINE_RECORDED]"
fi

step "A6: signal exit 130 (SIGINT) ignored even with rejection-shaped stderr"
reset_state
printf 'No conversation found with session ID: %s\n' "$UUID" >"$TMP/err.log"
sz=$(wc -c <"$TMP/err.log")
bridge_run_quarantine_rejected_resume 130 3 "$LAUNCH_RESUME" "$TMP/err.log" 0 "$sz" || true
if [[ -z "$QUARANTINE_RECORDED" ]]; then
  ok
else
  err "expected signal-exit ignored; got [$QUARANTINE_RECORDED]"
fi

step "A7: LAUNCH_CMD without --resume -> no quarantine"
reset_state
printf 'No conversation found with session ID: %s\n' "$UUID" >"$TMP/err.log"
sz=$(wc -c <"$TMP/err.log")
bridge_run_quarantine_rejected_resume 1 3 "$LAUNCH_FRESH" "$TMP/err.log" 0 "$sz" || true
if [[ -z "$QUARANTINE_RECORDED" ]]; then
  ok
else
  err "expected no-resume ignored; got [$QUARANTINE_RECORDED]"
fi

step "A8: clean exit (0) ignored"
reset_state
printf 'No conversation found with session ID: %s\n' "$UUID" >"$TMP/err.log"
sz=$(wc -c <"$TMP/err.log")
bridge_run_quarantine_rejected_resume 0 3 "$LAUNCH_RESUME" "$TMP/err.log" 0 "$sz" || true
if [[ -z "$QUARANTINE_RECORDED" ]]; then
  ok
else
  err "expected clean-exit ignored; got [$QUARANTINE_RECORDED]"
fi

# Issue #2106 — fix #2: the "subsequent launches will skip this transcript"
# reassurance must fire ONLY when the id is genuinely in the quarantine list,
# and a foreign-guard REFUSAL (quarantine_add rc=0 but recorded nothing) must
# log the truthful "NOT quarantined (foreign/refused)" line instead — never the
# false skip claim that masked the crash-loop on the downstream install.
step "A9a (genuine record): skip-reassurance log fires when id IS quarantined"
reset_state
printf 'No conversation found with session ID: %s\n' "$UUID" >"$TMP/err.log"
sz=$(wc -c <"$TMP/err.log")
bridge_run_quarantine_rejected_resume 1 3 "$LAUNCH_RESUME" "$TMP/err.log" 0 "$sz" || true
if printf '%s' "$LOG_LINES" | grep -q 'subsequent launches will skip this transcript' \
   && ! printf '%s' "$LOG_LINES" | grep -q 'NOT quarantined'; then
  ok
else
  err "expected skip-reassurance log on genuine record; got [$LOG_LINES]"
fi

step "A9b (foreign refusal): NO false skip-reassurance; truthful refusal logged"
reset_state
# Simulate the foreign-guard refusal: add returns 0 (its historical contract)
# but the id is NOT in the quarantine list afterward.
QUARANTINE_IDS_OVERRIDE=""
printf 'No conversation found with session ID: %s\n' "$UUID" >"$TMP/err.log"
sz=$(wc -c <"$TMP/err.log")
bridge_run_quarantine_rejected_resume 1 3 "$LAUNCH_RESUME" "$TMP/err.log" 0 "$sz" || true
if ! printf '%s' "$LOG_LINES" | grep -q 'subsequent launches will skip this transcript' \
   && printf '%s' "$LOG_LINES" | grep -q 'NOT quarantined'; then
  ok
else
  err "expected NO false skip log + truthful refusal log on foreign refusal; got [$LOG_LINES]"
fi

step "A9c (foreign refusal): archive is NOT attempted on a refusal"
reset_state
QUARANTINE_IDS_OVERRIDE=""
printf 'No conversation found with session ID: %s\n' "$UUID" >"$TMP/err.log"
sz=$(wc -c <"$TMP/err.log")
bridge_run_quarantine_rejected_resume 1 3 "$LAUNCH_RESUME" "$TMP/err.log" 0 "$sz" || true
if [[ -z "$ARCHIVE_CALLED" ]]; then
  ok
else
  err "expected NO archive on foreign refusal; got [$ARCHIVE_CALLED]"
fi

# ----------------------------------------------------------------------------
# Section B — run_forget_session quarantine clear paths
# ----------------------------------------------------------------------------
FS_TMP="$TMP/forget-session.sh"
awk '
  /^run_forget_session\(\) \{/ { copy = 1 }
  copy { print }
  /^\}$/ && copy { copy = 0; print ""; exit }
' "$ROOT_DIR/bridge-agent.sh" >"$FS_TMP"

# Stubs that emulate the bridge environment without pulling in the full
# library graph. The persisted-clear and active probes are controllable
# via globals so each case drives the helper independently.
PERSISTED_CHANGED="no"
ACTIVE_NO=1   # 1 => inactive, 0 => active

bridge_die()                       { printf 'die: %s\n' "$*" >&2; exit 1; }
bridge_require_agent()             { return 0; }
bridge_warn()                      { printf '[warn] %s\n' "$*" >&2; }
# bridge_audit_log is already stubbed above to return 0.
bridge_agent_is_active() { (( ACTIVE_NO == 0 )); }
bridge_clear_persisted_session_id() {
  if [[ "$PERSISTED_CHANGED" == "yes" ]]; then
    echo "prior_id_hash=abc123 changed=yes cleared_files=foo-history"
  else
    echo "prior_id_hash= changed=no cleared_files="
  fi
}
bridge_agent_resume_quarantine_file() {
  printf '%s/quar-%s.json\n' "$TMP" "$1"
}
bridge_agent_resume_quarantine_clear() {
  local agent="$1"
  rm -f "$(bridge_agent_resume_quarantine_file "$agent")" 2>/dev/null
  return 0
}

# shellcheck source=/dev/null
source "$FS_TMP"

setup_quarantine() {
  local agent="$1"
  printf '{"version":1,"quarantined":[{"session_id":"x"}]}' \
    >"$(bridge_agent_resume_quarantine_file "$agent")"
}

step "B1 (regression): changed=no + inactive + quarantine present -> CLEARED"
PERSISTED_CHANGED="no"; ACTIVE_NO=1
setup_quarantine b1
out="$(run_forget_session b1 2>&1)"
if grep -q "resume_quarantine_cleared: yes" <<<"$out" \
   && [[ ! -f "$(bridge_agent_resume_quarantine_file b1)" ]]; then
  ok
else
  err "expected clear on changed=no inactive; out=[$out]"
fi

step "B2: changed=no + inactive + NO quarantine -> reports no, no error"
PERSISTED_CHANGED="no"; ACTIVE_NO=1
out="$(run_forget_session b2 2>&1)"
if grep -q "resume_quarantine_cleared: no" <<<"$out"; then
  ok
else
  err "expected resume_quarantine_cleared: no; out=[$out]"
fi

step "B3: changed=no + ACTIVE + quarantine present -> preserved + warn"
PERSISTED_CHANGED="no"; ACTIVE_NO=0
setup_quarantine b3
out="$(run_forget_session b3 2>&1)"
if grep -q "resume_quarantine_cleared: no" <<<"$out" \
   && [[ -f "$(bridge_agent_resume_quarantine_file b3)" ]] \
   && grep -q "left intact" <<<"$out"; then
  ok
else
  err "expected active preserve + warn; out=[$out]"
fi

step "B4: changed=yes + inactive + quarantine present -> CLEARED"
PERSISTED_CHANGED="yes"; ACTIVE_NO=1
setup_quarantine b4
out="$(run_forget_session b4 2>&1)"
if grep -q "resume_quarantine_cleared: yes" <<<"$out" \
   && grep -q "^changed: yes" <<<"$out" \
   && [[ ! -f "$(bridge_agent_resume_quarantine_file b4)" ]]; then
  ok
else
  err "expected clear on changed=yes inactive; out=[$out]"
fi

step "B5: changed=yes + ACTIVE + quarantine present -> preserved + both warns"
PERSISTED_CHANGED="yes"; ACTIVE_NO=0
setup_quarantine b5
out="$(run_forget_session b5 2>&1)"
if grep -q "resume_quarantine_cleared: no" <<<"$out" \
   && [[ -f "$(bridge_agent_resume_quarantine_file b5)" ]] \
   && grep -q "must be restarted fresh" <<<"$out" \
   && grep -q "left intact" <<<"$out"; then
  ok
else
  err "expected active preserve + both warns; out=[$out]"
fi

printf '\nTotal: %d, Pass: %d, Fail: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
exit "$FAIL"
