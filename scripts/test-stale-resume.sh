#!/usr/bin/env bash
# Regression coverage for the "agb admin stale session-id resume" bug.
#
# Verifies bridge_resolve_resume_session_id (the freshness-gate resolver) and
# the legacy boolean wrappers that callers use during roster hydration and
# launch probes (bridge_claude_session_id_exists,
# bridge_claude_has_resumable_session_state). Runs in an isolated $HOME and
# $BRIDGE_HOME so it never reads or writes the operator's live runtime.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP_HOME="$(mktemp -d -t agb-stale-resume-test.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export BRIDGE_HOME="$TMP_HOME/.agent-bridge"
export BRIDGE_RESUME_MAX_AGE_HOURS=48

mkdir -p "$BRIDGE_HOME" "$HOME/.claude/sessions" "$HOME/.claude/projects"

# Extract just the three functions under test out of bridge-state.sh into a
# self-contained snippet. bridge-state.sh has heavy transitive dependencies
# (roster, persistence, etc) that this unit suite does not exercise.
EXTRACT_TMP="$TMP_HOME/extract.sh"
awk '
  /^bridge_resolve_resume_session_id\(\) \{/ ||
  /^bridge_claude_has_resumable_session_state\(\) \{/ ||
  /^bridge_claude_session_id_exists\(\) \{/ { copy = 1 }
  copy { print }
  copy && /^\}$/ { copy = 0; print "" }
' "$ROOT_DIR/lib/bridge-state.sh" >"$EXTRACT_TMP"

# shellcheck source=/dev/null
source "$EXTRACT_TMP"

mk_transcript() {
  local slug="$1" stem="$2" age_hours="$3"
  local dir="$HOME/.claude/projects/$slug"
  mkdir -p "$dir"
  local path="$dir/$stem.jsonl"
  printf '{"sessionId":"%s","type":"summary"}\n' "$stem" >"$path"
  local epoch=$(( $(date +%s) - age_hours * 3600 ))
  touch -d "@$epoch" "$path"
}

slug() { printf '%s' "$1" | sed 's,/,-,g'; }

WORKDIR="$HOME/agents/test-agent"
mkdir -p "$WORKDIR"
SLUG="$(slug "$WORKDIR")"

# --- Resolver unit cases -----------------------------------------------------

step "A: candidate stale (96h), no other transcripts -> rc=1, empty"
mk_transcript "$SLUG" "stale-A" 96
out=""
rc=0
out="$(bridge_resolve_resume_session_id claude test-agent "$WORKDIR" stale-A 2>/dev/null)" || rc=$?
if [[ "$rc" == 1 && -z "$out" ]]; then ok; else err "rc=$rc out='$out'"; fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "B: candidate fresh (1h), alone -> rc=0, accepted=candidate"
mk_transcript "$SLUG" "fresh-B" 1
out=""
rc=0
out="$(bridge_resolve_resume_session_id claude test-agent "$WORKDIR" fresh-B 2>/dev/null)" || rc=$?
if [[ "$rc" == 0 && "$out" == "fresh-B" ]]; then ok; else err "rc=$rc out='$out'"; fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "C: stale candidate + newer eligible -> rc=2, accepted=newer"
mk_transcript "$SLUG" "stale-C" 96
mk_transcript "$SLUG" "fresh-C" 1
out=""
rc=0
out="$(bridge_resolve_resume_session_id claude test-agent "$WORKDIR" stale-C 2>/dev/null)" || rc=$?
if [[ "$rc" == 2 && "$out" == "fresh-C" ]]; then ok; else err "rc=$rc out='$out'"; fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "D: candidate fresh but a fresher exists -> rc=2, accepted=fresher"
mk_transcript "$SLUG" "fresh-D" 5
mk_transcript "$SLUG" "fresher-D" 1
out=""
rc=0
out="$(bridge_resolve_resume_session_id claude test-agent "$WORKDIR" fresh-D 2>/dev/null)" || rc=$?
if [[ "$rc" == 2 && "$out" == "fresher-D" ]]; then ok; else err "rc=$rc out='$out'"; fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "E: codex engine passthrough -> rc=0, accepted=candidate"
out=""
rc=0
out="$(bridge_resolve_resume_session_id codex test-agent "$WORKDIR" anything 2>/dev/null)" || rc=$?
if [[ "$rc" == 0 && "$out" == "anything" ]]; then ok; else err "rc=$rc out='$out'"; fi

# --- Wrapper compatibility ---------------------------------------------------

step "W1: bridge_claude_session_id_exists rejects stale id"
mk_transcript "$SLUG" "stale-W1" 96
if bridge_claude_session_id_exists stale-W1 "$WORKDIR" 2>/dev/null; then
  err "expected false, got true"
else
  ok
fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "W2: bridge_claude_session_id_exists accepts fresh id"
mk_transcript "$SLUG" "fresh-W2" 1
if bridge_claude_session_id_exists fresh-W2 "$WORKDIR" 2>/dev/null; then
  ok
else
  err "expected true, got false"
fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "W3: bridge_claude_has_resumable_session_state false on stale-only workdir"
mk_transcript "$SLUG" "stale-W3" 96
if bridge_claude_has_resumable_session_state "$WORKDIR" 2>/dev/null; then
  err "expected false, got true"
else
  ok
fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "W4: bridge_claude_has_resumable_session_state true on fresh workdir"
mk_transcript "$SLUG" "fresh-W4" 1
if bridge_claude_has_resumable_session_state "$WORKDIR" 2>/dev/null; then
  ok
else
  err "expected true, got false"
fi
rm -rf "$HOME/.claude/projects/$SLUG"

# --- Summary ----------------------------------------------------------------

printf '\nTotal: %d, Pass: %d, Fail: %d\n' $((PASS + FAIL)) "$PASS" "$FAIL"
exit "$FAIL"
