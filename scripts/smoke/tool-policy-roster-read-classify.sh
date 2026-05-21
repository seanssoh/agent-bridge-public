#!/usr/bin/env bash
# scripts/smoke/tool-policy-roster-read-classify.sh — regression for
# issue #1014 sub-bug C (2026-05-22, r2).
#
# Two layers, because the r1 smoke covered only the helper in isolation
# and gave false confidence (codex r1 catch):
#
#   Layer 1 (helper unit) — tool-policy-roster-read-classify.py asserts
#     _is_read_intent_bash() treats a neutral prelude stage (cd / test /
#     echo / …) as transparent so a `cd … && grep` pipeline classifies
#     as read-intent.
#
#   Layer 2 (REAL PreToolUse hook) — this script invokes
#     hooks/tool-policy.py as an actual PreToolUse hook (stdin JSON ->
#     permissionDecision), with BRIDGE_HOME set and an
#     agent-roster.local.sh present, and asserts the end-to-end
#     allow/deny verdict. The r1 helper-only test missed that a
#     `cd $BRIDGE_HOME && …` prelude left the protected roster path
#     CWD-relative and therefore invisible to the argv path matcher —
#     reads passed by accident and, worse, WRITES passed too (a
#     protected-path bypass). The fix resolves a leading `cd <dir>`
#     prelude when matching argv fragments against the protected path.
#
# The hook-level cases mirror the exact codex r1 repro set:
#   cd $BRIDGE_HOME && grep BRIDGE agent-roster.local.sh   -> allowed
#   cd $BRIDGE_HOME && echo x > agent-roster.local.sh       -> DENIED
#   cd $BRIDGE_HOME && sed -i s/a/b/ agent-roster.local.sh  -> DENIED
#   cd / && echo x > $BRIDGE_HOME/agent-roster.local.sh     -> DENIED
#
# Footgun #11: the JSON stdin payload is built with `printf` (never an
# interpreter here-string / heredoc-stdin) and piped into the hook with
# `< file`, matching scripts/smoke/admin-hook-exemption.sh.

set -euo pipefail

SMOKE_NAME="tool-policy-roster-read-classify"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

# --- Layer 1: helper unit assertions ----------------------------------------

echo "[smoke:${SMOKE_NAME}] layer 1 — _is_read_intent_bash classifier unit"
"$PYTHON_BIN" "$SCRIPT_DIR/tool-policy-roster-read-classify.py"

# --- Layer 2: real PreToolUse hook end-to-end -------------------------------

smoke_setup_bridge_home "$SMOKE_NAME"

# The protected roster file must exist at $BRIDGE_HOME/agent-roster.local.sh
# (roster_local_path() = bridge_home_dir()/agent-roster.local.sh).
ROSTER_FILE="$BRIDGE_HOME/agent-roster.local.sh"
printf '%s\n' '# smoke roster fixture' 'BRIDGE_AGENT_CHANNELS=secret-token' >"$ROSTER_FILE"

# Admin agent — the #1014 scenario was an admin running roster
# diagnostics. is_admin_agent() honors SESSION-TYPE.md == admin.
AGENT="patch-1014"
AGENT_HOME="$BRIDGE_AGENT_HOME_ROOT/$AGENT"
mkdir -p "$AGENT_HOME"
printf -- '- session type: admin\n' >"$AGENT_HOME/SESSION-TYPE.md"

# JSON-escape a Bash command string for embedding in the payload.
# Escapes `\`, `"`, and a literal newline (the newline-separated cd
# prelude case carries one) as the JSON `\n` escape.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Write a PreToolUse Bash payload to a temp file with printf — no
# interpreter heredoc-stdin (footgun #11). $1 target file, $2 command.
write_bash_payload() {
  local target="$1"
  local command="$2"
  local esc
  esc="$(json_escape "$command")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1014",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

run_pretool_hook() {
  local payload_file="$1"
  BRIDGE_AGENT_ID="$AGENT" \
    "$PYTHON_BIN" "$SMOKE_REPO_ROOT/hooks/tool-policy.py" <"$payload_file"
}

# Assert the hook's verdict for a command. $1 label, $2 command, $3
# verdict (ALLOW|DENY). ALLOW = no `permissionDecision: deny` emitted.
assert_hook_verdict() {
  local label="$1"
  local command="$2"
  local want="$3"
  local payload out got
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM.json"
  write_bash_payload "$payload" "$command"
  out="$(run_pretool_hook "$payload")"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then
    got="DENY"
  else
    got="ALLOW"
  fi
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      command: ${command}"
    smoke_log "      hook output: ${out:-<empty>}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

echo "[smoke:${SMOKE_NAME}] layer 2 — real PreToolUse hook end-to-end"

# The exact codex r1 repro set — `&&` separator.
assert_hook_verdict \
  "cd-prelude (&&) grep (read) of roster" \
  "cd $BRIDGE_HOME && grep BRIDGE agent-roster.local.sh" \
  "ALLOW"

assert_hook_verdict \
  "cd-prelude (&&) echo-redirect (write) to roster" \
  "cd $BRIDGE_HOME && echo x > agent-roster.local.sh" \
  "DENY"

assert_hook_verdict \
  "cd-prelude (&&) sed -i (write) of roster" \
  "cd $BRIDGE_HOME && sed -i s/a/b/ agent-roster.local.sh" \
  "DENY"

# codex r2 repro set — `;` (no surrounding space) and newline separators.
# shlex.split() does not emit `;`/newline as standalone operator tokens
# in these forms, so the r2 cd-prelude detector missed them and the
# write bypass survived. The detector now uses the raw-string operator
# model, so every separator form must behave identically.
assert_hook_verdict \
  "cd-prelude (; no space) grep (read) of roster" \
  "cd $BRIDGE_HOME;grep BRIDGE agent-roster.local.sh" \
  "ALLOW"

assert_hook_verdict \
  "cd-prelude (; no space) echo-redirect (write) to roster" \
  "cd $BRIDGE_HOME;echo x > agent-roster.local.sh" \
  "DENY"

assert_hook_verdict \
  "cd-prelude (; no space) sed -i (write) of roster" \
  "cd $BRIDGE_HOME;sed -i s/a/b/ agent-roster.local.sh" \
  "DENY"

assert_hook_verdict \
  "cd-prelude (; spaced) echo-redirect (write) to roster" \
  "cd $BRIDGE_HOME ; echo x > agent-roster.local.sh" \
  "DENY"

assert_hook_verdict \
  "cd-prelude (newline) grep (read) of roster" \
  "$(printf 'cd %s\ngrep BRIDGE agent-roster.local.sh' "$BRIDGE_HOME")" \
  "ALLOW"

assert_hook_verdict \
  "cd-prelude (newline) echo-redirect (write) to roster" \
  "$(printf 'cd %s\necho x > agent-roster.local.sh' "$BRIDGE_HOME")" \
  "DENY"

assert_hook_verdict \
  "cd-prelude (newline) tee (write) of roster" \
  "$(printf 'cd %s\ntee agent-roster.local.sh' "$BRIDGE_HOME")" \
  "DENY"

assert_hook_verdict \
  "cd-prelude (||) echo-redirect (write) to roster" \
  "cd $BRIDGE_HOME || echo x > agent-roster.local.sh" \
  "DENY"

assert_hook_verdict \
  "absolute-path echo-redirect (write) to roster" \
  "cd / && echo x > $BRIDGE_HOME/agent-roster.local.sh" \
  "DENY"

# Absolute-path regression guards — the pre-#1014 cases must still hold.
assert_hook_verdict \
  "absolute-path grep (read) of roster" \
  "grep BRIDGE $ROSTER_FILE" \
  "ALLOW"

assert_hook_verdict \
  "absolute-path sed -i (write) of roster" \
  "sed -i s/a/b/ $ROSTER_FILE" \
  "DENY"

# A neutral test-prelude before the read must also stay allowed.
assert_hook_verdict \
  "test-prelude cat (read) of roster" \
  "cd $BRIDGE_HOME && test -f agent-roster.local.sh && cat agent-roster.local.sh" \
  "ALLOW"

smoke_log "passed"
