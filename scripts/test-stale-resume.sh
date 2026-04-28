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
  # Portable across BSD/macOS (no GNU touch -d "@N" support). os.utime
  # always exists on Python 3 and the float conversion handles the
  # epoch-second integer cleanly. dev-codex round-4 review #430 item 3.
  python3 - "$path" "$epoch" <<'PY'
import os, sys
path, epoch = sys.argv[1], float(sys.argv[2])
os.utime(path, (epoch, epoch))
PY
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

# --- Integration: bridge_load_dynamic_agent_file static-collision branch ---
#
# dev-codex round-4 review #430 item 1: the static-collision early-return in
# bridge_load_dynamic_agent_file used to import AGENT_SESSION_ID directly,
# bypassing the resolver. This test drives the function with a stale env file
# referencing an already-registered static agent and asserts the resolver
# rejected the stale id (BRIDGE_AGENT_SESSION_ID["x"] ends up empty, NOT the
# stale id from the env file).
#
# Implementation note: bridge_load_dynamic_agent_file has roster-side deps
# (bridge_agent_exists, bridge_agent_source, bridge_add_agent_id_if_missing).
# We override those with shell stubs so the integration test stays
# self-contained without sourcing the full lib/bridge-agents.sh + roster
# machinery. The behaviour under test is the resolver-gating branch only.

INTEG_EXTRACT="$TMP_HOME/integ-extract.sh"
awk '
  /^bridge_load_dynamic_agent_file\(\) \{/ { copy = 1 }
  copy { print }
  copy && /^\}$/ { copy = 0; print "" }
' "$ROOT_DIR/lib/bridge-state.sh" >"$INTEG_EXTRACT"

# shellcheck source=/dev/null
source "$INTEG_EXTRACT"

# Stubs for the static-collision branch's roster lookups. The test fixture
# treats "test-static" as a pre-existing static agent and nothing else.
declare -gA BRIDGE_AGENT_IDS_MAP=([test-static]=1)
declare -gA BRIDGE_AGENT_SOURCE=([test-static]=static)
declare -gA BRIDGE_AGENT_SESSION_ID=([test-static]="")
declare -gA BRIDGE_AGENT_HISTORY_KEY=()
declare -gA BRIDGE_AGENT_CREATED_AT=()
declare -gA BRIDGE_AGENT_UPDATED_AT=()

bridge_agent_exists() { [[ -n "${BRIDGE_AGENT_IDS_MAP[$1]+x}" ]]; }
bridge_agent_source() { printf '%s' "${BRIDGE_AGENT_SOURCE[$1]:-}"; }
bridge_add_agent_id_if_missing() { :; }

mk_env_file() {
  local file="$1" agent="$2" session_id="$3"
  cat >"$file" <<EOF
AGENT_ID="$agent"
AGENT_DESC="integration test"
AGENT_ENGINE="claude"
AGENT_SESSION="$agent"
AGENT_WORKDIR="$WORKDIR"
AGENT_LOOP="1"
AGENT_CONTINUE="1"
AGENT_SESSION_ID="$session_id"
AGENT_HISTORY_KEY="$agent"
AGENT_CREATED_AT="2026-04-24T00:00:00Z"
AGENT_UPDATED_AT="2026-04-24T00:00:00Z"
EOF
}

step "I1: bridge_load_dynamic_agent_file rejects stale id on static-collision branch (#430 item 1)"
mk_transcript "$SLUG" "stale-I1" 96
ENV_FILE="$TMP_HOME/i1.env"
mk_env_file "$ENV_FILE" "test-static" "stale-I1"
BRIDGE_AGENT_SESSION_ID["test-static"]=""
bridge_load_dynamic_agent_file "$ENV_FILE"
got="${BRIDGE_AGENT_SESSION_ID[test-static]:-<unset>}"
if [[ "$got" == "" || "$got" == "<unset>" ]]; then
  ok
else
  err "expected empty, got '$got' (stale id leaked through static-collision branch)"
fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "I2: bridge_load_dynamic_agent_file accepts fresh id on static-collision branch"
mk_transcript "$SLUG" "fresh-I2" 1
mk_env_file "$ENV_FILE" "test-static" "fresh-I2"
BRIDGE_AGENT_SESSION_ID["test-static"]=""
bridge_load_dynamic_agent_file "$ENV_FILE"
got="${BRIDGE_AGENT_SESSION_ID[test-static]:-<unset>}"
if [[ "$got" == "fresh-I2" ]]; then
  ok
else
  err "expected fresh-I2, got '$got'"
fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "I3: bridge_load_dynamic_agent_file static-collision branch swaps in fresher id when stored is stale"
mk_transcript "$SLUG" "stale-I3" 96
mk_transcript "$SLUG" "fresher-I3" 2
mk_env_file "$ENV_FILE" "test-static" "stale-I3"
BRIDGE_AGENT_SESSION_ID["test-static"]=""
bridge_load_dynamic_agent_file "$ENV_FILE"
got="${BRIDGE_AGENT_SESSION_ID[test-static]:-<unset>}"
if [[ "$got" == "fresher-I3" ]]; then
  ok
else
  err "expected fresher-I3 (rc=2 swap), got '$got'"
fi
rm -rf "$HOME/.claude/projects/$SLUG"

step "I4: static-collision rc=other does NOT preserve a pre-existing stale roster value (#446 fact-correction)"
# bridge_load_roster runs bridge_load_dynamic_agents BEFORE
# bridge_load_static_histories. So at the point this branch executes, any
# pre-existing BRIDGE_AGENT_SESSION_ID is the raw roster value, NOT a
# resolver-validated value. If the env file's candidate is also stale and
# we "preserve existing", a stale id from the roster leaks through.
# Round-5 had this bug; round-6 clears on rc=other.
mk_transcript "$SLUG" "stale-I4-env" 96
# Note: stale-I4-roster has NO transcript on disk so the resolver would
# reject it too if we attempted to gate it. The point is the BRANCH itself
# must clear the slot, not fall back to that ungated roster string.
mk_env_file "$ENV_FILE" "test-static" "stale-I4-env"
BRIDGE_AGENT_SESSION_ID["test-static"]="stale-I4-roster"
bridge_load_dynamic_agent_file "$ENV_FILE"
got="${BRIDGE_AGENT_SESSION_ID[test-static]:-<unset>}"
if [[ -z "$got" || "$got" == "<unset>" ]]; then
  ok
else
  err "expected empty (cleared), got '$got' — stale roster value leaked through static-collision rc=other branch"
fi
rm -rf "$HOME/.claude/projects/$SLUG"

# --- Structural guardrail: every "promised" entry point keeps a resolver call ---
#
# dev-codex round-4 review #430 item 2: the resolver wiring is documented in
# the PR body but no test demonstrates each named call site actually routes
# through bridge_resolve_resume_session_id. A grep-style structural guard is
# the cheapest proof and also catches future regressions where a refactor
# accidentally drops the resolver call from one of these sites.
#
# We don't try to prove the call is *correctly* used here — the integration
# tests above cover the static-collision branch directly, and the resolver
# unit tests A–E cover the resolver itself. This guard only proves "the
# resolver is mentioned within the function body of every site that the PR
# body claims is wired."

assert_function_calls_resolver() {
  local file="$1" function_name="$2"
  step "S/${function_name}: function body contains bridge_resolve_resume_session_id (#430 item 2)"
  python3 - "$file" "$function_name" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_text(errors="replace")
fn = sys.argv[2]
# Find the function body. Bash function form: `name() {\n ... \n}\n`.
# We don't try to handle nested braces — none of the targeted functions
# use top-level brace blocks inside their body, just heredocs and case.
pattern = re.compile(rf"^{re.escape(fn)}\(\)\s*\{{\s*\n(.*?)^\}}", re.MULTILINE | re.DOTALL)
match = pattern.search(src)
if not match:
    sys.stderr.write(f"function '{fn}' not found in {sys.argv[1]}\n")
    sys.exit(2)
body = match.group(1)
if "bridge_resolve_resume_session_id" not in body:
    sys.stderr.write(
        f"function '{fn}' does not call bridge_resolve_resume_session_id "
        f"(this is the regression dev-codex review #430 item 2 was guarding "
        f"against — a wiring site lost its resolver call)\n"
    )
    sys.exit(1)
PY
  if [[ $? -eq 0 ]]; then ok; else err "missing resolver call in $function_name (see stderr)"; fi
}

assert_function_calls_resolver "$ROOT_DIR/lib/bridge-state.sh" "bridge_load_dynamic_agent_file"
assert_function_calls_resolver "$ROOT_DIR/lib/bridge-state.sh" "bridge_restore_dynamic_agents_from_history"
assert_function_calls_resolver "$ROOT_DIR/lib/bridge-state.sh" "_bridge_register_dynamic_from_env_file"
assert_function_calls_resolver "$ROOT_DIR/lib/bridge-state.sh" "bridge_load_static_agent_history"
assert_function_calls_resolver "$ROOT_DIR/lib/bridge-state.sh" "bridge_claude_resume_session_id_for_agent"

# agent-bridge root dispatcher: the dynamic ad-hoc `--continue` / `--codex` /
# `--claude` launch path lives outside any named bash function, so the
# function-body extractor used above does not apply. Instead we assert that
# `bridge_resolve_resume_session_id` is mentioned anywhere in the file —
# which is sufficient because the only non-test reference in agent-bridge is
# the dispatcher's resume-id resolution. A regression that drops the call
# would also drop the only mention.
step "S/root-dispatcher: agent-bridge mentions bridge_resolve_resume_session_id (#430 item 2)"
if grep -q "bridge_resolve_resume_session_id" "$ROOT_DIR/agent-bridge"; then
  ok
else
  err "agent-bridge no longer mentions bridge_resolve_resume_session_id"
fi

# bridge-sync.sh sits at the repo root (not under scripts/).
assert_function_calls_resolver "$ROOT_DIR/bridge-sync.sh" "refresh_missing_session_ids"

# --- Summary ----------------------------------------------------------------

printf '\nTotal: %d, Pass: %d, Fail: %d\n' $((PASS + FAIL)) "$PASS" "$FAIL"
exit "$FAIL"
