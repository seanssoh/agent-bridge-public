#!/usr/bin/env bash
# system-config-gating smoke — issue #341 hook + wrapper coverage.
#
# Asserts the runtime contract for every audit row trigger:
#
#   1. Hook denial path: feed a synthetic Claude PreToolUse Edit payload
#      against agents/x/.discord/access.json into hooks/tool-policy.py.
#      Expect deny + a `system_config_mutation` audit row with
#      `trigger=hook-deny`, no `after_sha256` field (codex r1 #341 CP3).
#
#   2. Wrapper happy path: invoke `bridge-config.py set` from operator-
#      attached TUI context (BRIDGE_CALLER_SOURCE=operator-tui) with
#      --from <admin>. Expect the file mutated + a `system_config_mutation`
#      audit row with `trigger=wrapper-apply` and matching before/after
#      sha256. `after_sha256` MUST be present (the only trigger that
#      records it).
#
#   3. Wrapper denial — non-admin caller: invoke from a non-admin
#      BRIDGE_AGENT_ID. Expect refusal + `wrapper-deny` audit row,
#      no `after_sha256`.
#
#   4. Wrapper denial — untrusted ID-match attempt: caller-source falls
#      back to `agent-direct` (no TTY, no env override). Expect refusal
#      + `wrapper-deny` audit row, no `after_sha256`.
#
#   5. list-protected is read-only and unrestricted (no audit row).
#
#   6. Wrapper denial — non-JSON path: invoke `set` against
#      agent-roster.local.sh (a shell file in PROTECTED_GLOBS). Expect
#      refusal + `wrapper-deny` audit row with reason mentioning the
#      manual flow, no `after_sha256` (codex r1 #341 CP10).
#
# Every audit row is structurally validated (Fix CP8): kind, trigger,
# path, before_sha256, actor, actor_source, operation, conditional
# after_sha256.
#
# Uses an isolated mktemp BRIDGE_HOME — never touches the live install.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi

BRIDGE_HOME="$(mktemp -d -t agb-341-smoke.XXXXXX)"
export BRIDGE_HOME
trap 'rm -rf "$BRIDGE_HOME"' EXIT

ADMIN_AGENT="patch"
NON_ADMIN_AGENT="huchu"
ACCESS_PATH="$BRIDGE_HOME/agents/$ADMIN_AGENT/.discord/access.json"
ROSTER_PATH="$BRIDGE_HOME/agent-roster.local.sh"
AUDIT_LOG="$BRIDGE_HOME/logs/audit.jsonl"

mkdir -p "$BRIDGE_HOME/agents/$ADMIN_AGENT/.discord"
mkdir -p "$BRIDGE_HOME/logs"
cat >"$ACCESS_PATH" <<'JSON'
{
  "version": 1,
  "groups": [],
  "policy": "owner-only"
}
JSON

cat >"$ROSTER_PATH" <<'SH'
# agent-roster.local.sh fixture for #341 smoke
export BRIDGE_AGENT_CHANNELS_patch="discord:fixture"
SH

PASS=0
FAIL=0
FAILURES=()

pass() {
  PASS=$((PASS + 1))
  printf '[smoke][pass] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '[smoke][fail] %s\n' "$1" >&2
}

# audit_row_shape_check <expected_trigger> <expected_path> <expect_after_sha256: 0|1>
#
# Walks the audit log for the most recent system_config_mutation row whose
# trigger and path match the expected values, then validates the field
# contract (codex r1 #341 CP8):
#   - kind == "system_config_mutation"
#   - trigger ∈ {hook-deny, wrapper-apply, wrapper-deny}
#   - path matches expected
#   - before_sha256 non-empty
#   - after_sha256 present iff trigger == wrapper-apply (per CP3)
#   - actor and actor_source non-empty strings
#   - operation field present
audit_row_shape_check() {
  local trigger="$1"
  local expected_path="$2"
  local expect_after="$3"
  [[ -f "$AUDIT_LOG" ]] || return 1
  "$PYTHON" - "$AUDIT_LOG" "$trigger" "$expected_path" "$expect_after" <<'PY'
import json, sys
log_path, trigger, expected_path, expect_after_raw = sys.argv[1:5]
expect_after = expect_after_raw == "1"
matches = []
with open(log_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        detail = row.get("detail")
        if not isinstance(detail, dict):
            continue
        if detail.get("kind") != "system_config_mutation":
            continue
        if detail.get("trigger") != trigger:
            continue
        if expected_path and detail.get("path") != expected_path:
            continue
        matches.append(detail)
if not matches:
    print(f"no row matched trigger={trigger} path={expected_path}", file=sys.stderr)
    sys.exit(2)
detail = matches[-1]
errors = []
allowed_triggers = {"hook-deny", "wrapper-apply", "wrapper-deny"}
if detail.get("trigger") not in allowed_triggers:
    errors.append(f"unexpected trigger {detail.get('trigger')!r}")
before = detail.get("before_sha256")
if not isinstance(before, str) or not before:
    errors.append("before_sha256 missing/empty")
has_after = "after_sha256" in detail
if expect_after:
    if not has_after:
        errors.append("after_sha256 missing on wrapper-apply row")
    else:
        after = detail.get("after_sha256")
        if not isinstance(after, str) or not after:
            errors.append("after_sha256 empty on wrapper-apply row")
else:
    if has_after:
        errors.append(
            f"after_sha256 must be absent on trigger={detail.get('trigger')!r} "
            "(codex r1 #341 CP3)"
        )
actor = detail.get("actor")
if not isinstance(actor, str) or not actor:
    errors.append("actor missing/empty")
actor_source = detail.get("actor_source")
if not isinstance(actor_source, str) or not actor_source:
    errors.append("actor_source missing/empty")
if "operation" not in detail:
    errors.append("operation field missing")
if errors:
    for err in errors:
        print(err, file=sys.stderr)
    sys.exit(3)
sys.exit(0)
PY
}

run_hook_pretool_payload() {
  local payload="$1"
  local agent="$2"
  BRIDGE_AGENT_ID="$agent" \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
    BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
    "$PYTHON" "$REPO_ROOT/hooks/tool-policy.py" <<<"$payload"
}

# --- Scenario 1: hook denial path ---------------------------------------
sce1_payload=$(cat <<JSON
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Edit",
  "tool_use_id": "test-1",
  "session_id": "test-session-1",
  "tool_input": {
    "file_path": "$ACCESS_PATH",
    "old_string": "[]",
    "new_string": "[12345]"
  }
}
JSON
)

sce1_out="$(run_hook_pretool_payload "$sce1_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce1_out" == *'"permissionDecision"'*'"deny"'* ]] && [[ "$sce1_out" == *"system config path"* ]]; then
  pass "scenario 1: hook denied Edit on protected access.json"
else
  fail "scenario 1: hook did not deny — output: $sce1_out"
fi

if sce1_shape_err="$(audit_row_shape_check "hook-deny" "$ACCESS_PATH" 0 2>&1)"; then
  pass "scenario 1: hook-deny audit row shape valid (no after_sha256)"
else
  fail "scenario 1: hook-deny audit row shape invalid — $sce1_shape_err"
fi

# --- Scenario 2: wrapper happy path -------------------------------------
# Operator at a TTY → BRIDGE_CALLER_SOURCE=operator-tui. caller agent
# must be the admin id (codex r1 #341 CP5: anonymous caller is denied).
before_sha="$("$PYTHON" -c "import hashlib,sys; sys.stdout.write(hashlib.sha256(open('$ACCESS_PATH','rb').read()).hexdigest())")"
sce2_out="$(BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_AGENT_ID="$ADMIN_AGENT" \
  "$PYTHON" "$REPO_ROOT/bridge-config.py" set \
    --path "$ACCESS_PATH" \
    --change "groups.append=12345" 2>&1 || true)"
after_sha="$("$PYTHON" -c "import hashlib,sys; sys.stdout.write(hashlib.sha256(open('$ACCESS_PATH','rb').read()).hexdigest())")"
if [[ "$sce2_out" == applied:* ]] && [[ "$before_sha" != "$after_sha" ]]; then
  pass "scenario 2: wrapper applied groups.append=12345"
else
  fail "scenario 2: wrapper did not apply — output: $sce2_out / before=$before_sha after=$after_sha"
fi

if "$PYTHON" -c "
import json,sys
data=json.load(open('$ACCESS_PATH'))
sys.exit(0 if data.get('groups')==[12345] else 1)
"; then
  pass "scenario 2: groups list now [12345]"
else
  fail "scenario 2: groups list did not become [12345]"
fi

if sce2_shape_err="$(audit_row_shape_check "wrapper-apply" "$ACCESS_PATH" 1 2>&1)"; then
  pass "scenario 2: wrapper-apply audit row shape valid (after_sha256 present)"
else
  fail "scenario 2: wrapper-apply audit row shape invalid — $sce2_shape_err"
fi

# --- Scenario 3: wrapper denial — non-admin caller ----------------------
sce3_out="$(BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_AGENT_ID="$NON_ADMIN_AGENT" \
  "$PYTHON" "$REPO_ROOT/bridge-config.py" set \
    --path "$ACCESS_PATH" \
    --change "groups.append=99999" 2>&1 || true)"
if [[ "$sce3_out" == *"deny:"* ]] && [[ "$sce3_out" == *"not the admin"* ]]; then
  pass "scenario 3: wrapper rejected non-admin caller"
else
  fail "scenario 3: wrapper did not reject non-admin — output: $sce3_out"
fi

if sce3_shape_err="$(audit_row_shape_check "wrapper-deny" "$ACCESS_PATH" 0 2>&1)"; then
  pass "scenario 3: wrapper-deny audit row shape valid (no after_sha256)"
else
  fail "scenario 3: wrapper-deny audit row shape invalid — $sce3_shape_err"
fi

# Confirm the file was NOT mutated.
if "$PYTHON" -c "
import json,sys
data=json.load(open('$ACCESS_PATH'))
sys.exit(1 if 99999 in data.get('groups',[]) else 0)
"; then
  pass "scenario 3: file unchanged after non-admin deny"
else
  fail "scenario 3: file was mutated despite deny"
fi

# --- Scenario 4: wrapper denial — untrusted source -----------------------
# Caller is the admin id but caller-source is agent-direct (no TTY, no env
# override). Mirrors the channel-message path: the message sender is not
# a verified operator, so even if the queue task says "patch please run X"
# the wrapper refuses.
sce4_out="$(BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_CALLER_SOURCE="agent-direct" \
  "$PYTHON" "$REPO_ROOT/bridge-config.py" set \
    --path "$ACCESS_PATH" \
    --change "groups.append=88888" \
    </dev/null 2>&1 || true)"
if [[ "$sce4_out" == *"deny:"* ]] && [[ "$sce4_out" == *"agent-direct"* ]]; then
  pass "scenario 4: wrapper rejected untrusted-source admin call"
else
  fail "scenario 4: wrapper did not reject untrusted source — output: $sce4_out"
fi

if sce4_shape_err="$(audit_row_shape_check "wrapper-deny" "$ACCESS_PATH" 0 2>&1)"; then
  pass "scenario 4: wrapper-deny audit row shape valid (no after_sha256)"
else
  fail "scenario 4: wrapper-deny audit row shape invalid — $sce4_shape_err"
fi

# --- Scenario 5: list-protected is read-only and unrestricted -----------
sce5_out="$(BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_AGENT_ID="$NON_ADMIN_AGENT" \
  "$PYTHON" "$REPO_ROOT/bridge-config.py" list-protected 2>&1 || true)"
if [[ "$sce5_out" == *"agents/*/.discord/access.json"* ]]; then
  pass "scenario 5: list-protected shows access.json glob"
else
  fail "scenario 5: list-protected did not include access.json — output: $sce5_out"
fi

if [[ "$sce5_out" == *"agent-roster.local.sh"* ]]; then
  pass "scenario 5: list-protected shows agent-roster.local.sh"
else
  fail "scenario 5: list-protected did not include agent-roster.local.sh — output: $sce5_out"
fi

# --- Scenario 6: wrapper denial — non-JSON protected path ---------------
# agent-roster.local.sh is a shell file in PROTECTED_GLOBS. Wrapper must
# refuse with a wrapper-deny row + a manual-flow message; the operator
# uses the queued admin task to edit the shell file by hand. Codex r1
# #341 CP10 surfaced this gap — the path was implemented but never
# exercised by smoke.
sce6_out="$(BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_AGENT_ID="$ADMIN_AGENT" \
  "$PYTHON" "$REPO_ROOT/bridge-config.py" set \
    --path "$ROSTER_PATH" \
    --change "BRIDGE_AGENT_CHANNELS_patch=discord:other" 2>&1 || true)"
if [[ "$sce6_out" == *"deny:"* ]] && [[ "$sce6_out" == *"not yet wrapper-mutable"* ]]; then
  pass "scenario 6: wrapper rejected non-JSON protected path (agent-roster.local.sh)"
else
  fail "scenario 6: wrapper did not reject non-JSON path — output: $sce6_out"
fi

if sce6_shape_err="$(audit_row_shape_check "wrapper-deny" "$ROSTER_PATH" 0 2>&1)"; then
  pass "scenario 6: non-JSON wrapper-deny audit row shape valid (no after_sha256)"
else
  fail "scenario 6: non-JSON wrapper-deny audit row shape invalid — $sce6_shape_err"
fi

# Confirm the roster file was NOT mutated by the failed call.
if grep -q "discord:fixture" "$ROSTER_PATH" && ! grep -q "discord:other" "$ROSTER_PATH"; then
  pass "scenario 6: agent-roster.local.sh contents unchanged after deny"
else
  fail "scenario 6: roster file was mutated despite deny"
fi

# --- Scenario 7: tool-policy false positive on .agents/ runtime dir ------
# Issue #509 D2 follow-up. A heredoc body whose prose contains a generic
# directory mention like `hooks/post.sh` or `state/cron/` and an
# unbalanced apostrophe (e.g. "the agent's hook chain at hooks/post.sh")
# used to trip the substring fallback in `_bash_argv_references_system_config`
# when shlex.split rejected the unbalanced quote — denying every write
# to a project-level `.agents/` working directory. The fallback now
# requires short needles to sit at a strict filesystem-prefix boundary
# (`/`, `~`, `$`), so prose mentions pass while real path arguments
# (`/abs/.../hooks/foo`) keep firing.

# D2a — Bash heredoc append to .agents/foo.md MUST NOT be denied.
sce7_payload=$(cat <<'JSON'
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7a",
  "session_id": "test-session-7a",
  "tool_input": {
    "command": "cat >> .agents/foo.md <<'EOF'\nThe agent's hook chain at hooks/post.sh writes to /tmp.\nEOF",
    "description": "append handoff"
  }
}
JSON
)
sce7_out="$(run_hook_pretool_payload "$sce7_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7_out" == *'"deny"'* ]]; then
  fail "scenario 7 (D2a): heredoc append to .agents/foo.md falsely denied — output: $sce7_out"
else
  pass "scenario 7 (D2a): Bash heredoc append to .agents/foo.md not denied"
fi

# D2b — Bash echo redirect to .agents/handoff.md MUST NOT be denied.
sce7b_payload=$(cat <<'JSON'
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7b",
  "session_id": "test-session-7b",
  "tool_input": {
    "command": "echo hi > .agents/handoff.md",
    "description": "write handoff"
  }
}
JSON
)
sce7b_out="$(run_hook_pretool_payload "$sce7b_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7b_out" == *'"deny"'* ]]; then
  fail "scenario 7 (D2b): echo redirect to .agents/handoff.md falsely denied — output: $sce7b_out"
else
  pass "scenario 7 (D2b): Bash echo to .agents/handoff.md not denied"
fi

# D2c — Edit tool to <workdir>/.agents/handoff.md MUST NOT be denied.
TMP_WORKDIR="$(mktemp -d -t agb-d2-workdir.XXXXXX)"
mkdir -p "$TMP_WORKDIR/.agents"
printf 'placeholder\n' >"$TMP_WORKDIR/.agents/handoff.md"
sce7c_payload=$(cat <<JSON
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Edit",
  "tool_use_id": "test-7c",
  "session_id": "test-session-7c",
  "tool_input": {
    "file_path": "$TMP_WORKDIR/.agents/handoff.md",
    "old_string": "placeholder",
    "new_string": "updated"
  }
}
JSON
)
sce7c_out="$(run_hook_pretool_payload "$sce7c_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7c_out" == *'"deny"'* ]]; then
  fail "scenario 7 (D2c): Edit on <workdir>/.agents/handoff.md falsely denied — output: $sce7c_out"
else
  pass "scenario 7 (D2c): Edit on .agents/handoff.md not denied"
fi
rm -rf "$TMP_WORKDIR"

# D2d — Regression: real protected path with unbalanced quote MUST still
# fire via the substring fallback. The needle here (`.discord/access.json`)
# is long enough to bypass the path-prefix-boundary requirement.
sce7d_payload=$(cat <<JSON
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7d",
  "session_id": "test-session-7d",
  "tool_input": {
    "command": "sqlite3 $BRIDGE_HOME/agents/$ADMIN_AGENT/.discord/access.json 'SELECT *",
    "description": "unbalanced quote with real protected path"
  }
}
JSON
)
sce7d_out="$(run_hook_pretool_payload "$sce7d_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7d_out" == *'"deny"'* ]] && [[ "$sce7d_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2d): unbalanced-quote substring fallback still fires on real protected path"
else
  fail "scenario 7 (D2d): substring fallback regression — real protected path no longer denied: $sce7d_out"
fi

# D2e — Bash redirect into hooks/ with unbalanced quote MUST deny.
# Issue #509 D2 r2 (codex needs-more): the original three-char prefix
# set `{/,~,$}` missed the `>hooks/` form, so a malformed real write
# slipped through the fallback. `>` is now in _PATH_PREFIX_CHARS.
sce7e_payload=$(cat <<'JSON'
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7e",
  "session_id": "test-session-7e",
  "tool_input": {
    "command": "cat >hooks/foo 'unterminated",
    "description": "redirect into hooks/ with unbalanced quote"
  }
}
JSON
)
sce7e_out="$(run_hook_pretool_payload "$sce7e_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7e_out" == *'"deny"'* ]] && [[ "$sce7e_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2e): \`cat >hooks/foo 'unterminated\` denied via expanded prefix set"
else
  fail "scenario 7 (D2e): \`>hooks/foo\` not denied — output: $sce7e_out"
fi

# D2f — Bash redirect into state/cron/ with unbalanced quote MUST deny.
# Reviewer's second explicit bypass for the original narrow prefix set.
sce7f_payload=$(cat <<'JSON'
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7f",
  "session_id": "test-session-7f",
  "tool_input": {
    "command": "cat >state/cron/job.json 'unterminated",
    "description": "redirect into state/cron/ with unbalanced quote"
  }
}
JSON
)
sce7f_out="$(run_hook_pretool_payload "$sce7f_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7f_out" == *'"deny"'* ]] && [[ "$sce7f_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2f): \`cat >state/cron/job.json 'unterminated\` denied via expanded prefix set"
else
  fail "scenario 7 (D2f): \`>state/cron/job.json\` not denied — output: $sce7f_out"
fi

# D2g — short needle at start-of-string (idx==0) MUST deny.
# Without the explicit `idx == 0` short-circuit, `hooks/post.sh ...` at
# the very start of a malformed command would slip through because the
# original loop required `idx > 0` and a prefix char before the needle.
sce7g_payload=$(cat <<'JSON'
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7g",
  "session_id": "test-session-7g",
  "tool_input": {
    "command": "hooks/post.sh some-arg-with-quote'",
    "description": "short needle at start-of-string with unbalanced quote"
  }
}
JSON
)
sce7g_out="$(run_hook_pretool_payload "$sce7g_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7g_out" == *'"deny"'* ]] && [[ "$sce7g_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2g): short needle at start-of-string denied via idx==0 short-circuit"
else
  fail "scenario 7 (D2g): start-of-string needle not denied — output: $sce7g_out"
fi

# D2h — Regression-preserve: heredoc prose with `hooks/post.sh` preceded
# by a SPACE must still NOT deny. Whitespace is deliberately excluded
# from the expanded _PATH_PREFIX_CHARS so prose mentions inside heredoc
# bodies keep passing. Mirrors the existing D2a case but written as an
# explicit r2 regression-preserve check.
sce7h_payload=$(cat <<'JSON'
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7h",
  "session_id": "test-session-7h",
  "tool_input": {
    "command": "cat >> .agents/X.md <<'EOF'\nThe chain at hooks/post.sh writes to /tmp.\nEOF",
    "description": "heredoc prose preserve"
  }
}
JSON
)
sce7h_out="$(run_hook_pretool_payload "$sce7h_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7h_out" == *'"deny"'* ]]; then
  fail "scenario 7 (D2h): heredoc prose 'the chain at hooks/post.sh' falsely denied — output: $sce7h_out"
else
  pass "scenario 7 (D2h): heredoc prose preceded by whitespace still passes (regression-preserve)"
fi

# D2i (Issue #1574) — false-positive fix: a report written to a NON-config
# area (~/.agent-bridge/shared/) with a simple `cat > file <<'EOF'` write and a
# QUOTED heredoc delimiter (so the body is provably literal — no expansion),
# whose BODY documents the hook chain with a path-boundary `hooks/` mention
# ('hooks/tool-policy.py') and an apostrophe (forcing shlex ValueError →
# substring fallback), must NOT deny. The redirect TARGET (shared/) is not
# protected; the `hooks/` needle is only inside the inert body prose. Only the
# quoted-delimiter simple cat/tee shape is strippable (see
# _command_is_simple_inert_quoted_heredoc_write) — anything that could execute
# the body stays conservative (D2k/D2l/D2m).
IFS= read -r -d '' sce7i_payload <<'JSON' || true
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7i",
  "session_id": "test-session-7i",
  "tool_input": {
    "command": "cat > shared/report.md <<'EOF'\nThe noise comes from 'hooks/tool-policy.py'; that's non-blocking.\nEOF",
    "description": "report write to shared/ documenting the hook chain"
  }
}
JSON
sce7i_out="$(run_hook_pretool_payload "$sce7i_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7i_out" == *'"deny"'* ]]; then
  fail "scenario 7 (D2i #1574): shared/ report mentioning 'hooks/...' in body falsely denied — output: $sce7i_out"
else
  pass "scenario 7 (D2i #1574): shared/ quoted-heredoc report with hooks/ mention in body not denied"
fi

# D2j (Issue #1574) — teeth-preserve: a REAL write whose redirect TARGET is a
# protected path (hooks/) MUST still deny EVEN when the command is the otherwise
# strippable simple quoted-heredoc shape. The body strip removes only the body,
# never the target (it keeps the head up to `<<'EOF'`), so the `hooks/` needle
# still fires at the redirect boundary in the retained head.
IFS= read -r -d '' sce7j_payload <<'JSON' || true
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7j",
  "session_id": "test-session-7j",
  "tool_input": {
    "command": "cat >hooks/evil.py <<'EOF'\nimport os  # it's evil\nEOF",
    "description": "real write into hooks/ via strippable quoted-heredoc shape"
  }
}
JSON
sce7j_out="$(run_hook_pretool_payload "$sce7j_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7j_out" == *'"deny"'* ]] && [[ "$sce7j_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2j #1574): real write into hooks/ target still denied after body strip"
else
  fail "scenario 7 (D2j #1574): real write into hooks/ NOT denied — output: $sce7j_out"
fi

# D2k (Issue #1574, codex r1 BLOCKING) — interpreter teeth-preserve: when the
# heredoc body is fed to a STDIN-EXECUTING interpreter (`bash <<EOF`), the body
# lines ARE commands and a `>hooks/evil.py` write inside the body is a REAL
# protected write. The body-strip is gated on _heredoc_body_is_inert_data, which
# fail-closes for interpreters, so the raw body stays on the scan surface and
# the gate MUST deny. Without the gate this command bypassed the guard.
IFS= read -r -d '' sce7k_payload <<'JSON' || true
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7k",
  "session_id": "test-session-7k",
  "tool_input": {
    "command": "cd ~/.agent-bridge && bash <<EOF\ncat >hooks/evil.py\nit's bad\nEOF",
    "description": "interpreter executes heredoc body that writes into hooks/"
  }
}
JSON
sce7k_out="$(run_hook_pretool_payload "$sce7k_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7k_out" == *'"deny"'* ]] && [[ "$sce7k_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2k #1574): bash-interpreter heredoc body writing hooks/ still denied (no interpreter bypass)"
else
  fail "scenario 7 (D2k #1574): interpreter heredoc-body write NOT denied — output: $sce7k_out"
fi

# D2l (Issue #1574) — pipe-to-interpreter teeth-preserve: `cat <<EOF | bash`
# pipes the body to an interpreter, so the body executes. Must still deny.
IFS= read -r -d '' sce7l_payload <<'JSON' || true
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7l",
  "session_id": "test-session-7l",
  "tool_input": {
    "command": "cat <<EOF | bash\ncat >hooks/evil.py\nit's bad\nEOF",
    "description": "heredoc body piped into interpreter that writes into hooks/"
  }
}
JSON
sce7l_out="$(run_hook_pretool_payload "$sce7l_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7l_out" == *'"deny"'* ]] && [[ "$sce7l_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2l #1574): cat <<EOF | bash body writing hooks/ still denied"
else
  fail "scenario 7 (D2l #1574): piped-interpreter heredoc-body write NOT denied — output: $sce7l_out"
fi

# D2m (Issue #1574, codex r2 BLOCKING) — process-substitution teeth-preserve:
# `cat > >(bash) <<EOF` uses an inert sink (cat) but redirects its output into a
# process-substitution interpreter `>(bash)`, which executes the body. The `>(`
# shell-exec construct means the command is NOT the simple-quoted-heredoc shape
# (_command_is_simple_inert_quoted_heredoc_write returns False), so the raw body
# stays on the scan surface and the gate MUST deny.
IFS= read -r -d '' sce7m_payload <<'JSON' || true
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7m",
  "session_id": "test-session-7m",
  "tool_input": {
    "command": "cd ~/.agent-bridge && cat > >(bash) <<EOF\ncat >hooks/evil.py\nit's bad\nEOF",
    "description": "cat into process-substitution interpreter that writes into hooks/"
  }
}
JSON
sce7m_out="$(run_hook_pretool_payload "$sce7m_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7m_out" == *'"deny"'* ]] && [[ "$sce7m_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2m #1574): cat > >(bash) procsub body writing hooks/ still denied"
else
  fail "scenario 7 (D2m #1574): process-substitution heredoc-body write NOT denied — output: $sce7m_out"
fi

# D2n (Issue #1574, codex r3 BLOCKING) — variable-backed FIFO teeth-preserve:
# `cmd=bash; mkfifo p; $cmd <p & cat >p <<EOF` runs an interpreter named only
# through a variable ($cmd) and feeds it the heredoc body via a named pipe. No
# literal interpreter basename and the inert sink (cat) write `>p` looks benign,
# but the body IS executed. The command has multiple stages / `&` / `$`, so it
# is not the simple-quoted-heredoc shape → raw body scanned → MUST deny.
IFS= read -r -d '' sce7n_payload <<'JSON' || true
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7n",
  "session_id": "test-session-7n",
  "tool_input": {
    "command": "cd ~/.agent-bridge && cmd=bash; mkfifo p; $cmd <p & cat >p <<EOF\ncat >hooks/evil.py\nit's bad\nEOF",
    "description": "variable-backed FIFO interpreter consuming the heredoc body"
  }
}
JSON
sce7n_out="$(run_hook_pretool_payload "$sce7n_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7n_out" == *'"deny"'* ]] && [[ "$sce7n_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2n #1574): variable-backed FIFO interpreter body writing hooks/ still denied"
else
  fail "scenario 7 (D2n #1574): FIFO-interpreter heredoc-body write NOT denied — output: $sce7n_out"
fi

# D2o (Issue #1574) — unquoted-heredoc teeth-preserve: an UNQUOTED `<<EOF` body
# is subject to shell expansion, so a `$(...)` inside it EXECUTES. The strip
# only applies to QUOTED delimiters, so this unquoted body stays on the scan
# surface and the embedded `>hooks/evil.py` write MUST deny.
IFS= read -r -d '' sce7o_payload <<'JSON' || true
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test-7o",
  "session_id": "test-session-7o",
  "tool_input": {
    "command": "cat > shared/r.md <<EOF\n$(cat >hooks/evil.py) it's data\nEOF",
    "description": "unquoted heredoc body with command substitution that writes hooks/"
  }
}
JSON
sce7o_out="$(run_hook_pretool_payload "$sce7o_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce7o_out" == *'"deny"'* ]] && [[ "$sce7o_out" == *"system config path"* ]]; then
  pass "scenario 7 (D2o #1574): unquoted heredoc with \$(...) writing hooks/ still denied"
else
  fail "scenario 7 (D2o #1574): unquoted-heredoc command-substitution write NOT denied — output: $sce7o_out"
fi

# --- Scenario 8: stderr-suppression read-intent on protected path -------
# Issue #574 + r2 follow-up. The three safe-redirect forms
# (`2>/dev/null`, `2>&1`, `&>/dev/null`) must be classified as read-intent
# so a `grep`/`cat`/`tail` on a protected file (allowed for any agent
# under #383's read-bypass) is not falsely denied. Real writes — including
# write redirects that *contain* a safe form, and substring-traps like
# `2>/dev/null/extra` (a real write to a path under /dev/null/) — must
# still deny. Each scenario reuses the protected access.json so the
# system-config gate is the one actually tested.

emit_bash_payload() {
  # $1: tool_use_id, $2: command (single-quoted JSON-safe)
  local id="$1" cmd="$2"
  "$PYTHON" - "$id" "$cmd" <<'PY'
import json, sys
tool_use_id, command = sys.argv[1], sys.argv[2]
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_use_id": tool_use_id,
    "session_id": f"test-session-{tool_use_id}",
    "tool_input": {"command": command, "description": "574 r2 smoke"},
}))
PY
}

# 8a — safe-redirect read on protected path MUST be allowed (any agent)
for form in "2>/dev/null" "2>&1" "&>/dev/null"; do
  cmd="grep -nE x $ACCESS_PATH $form"
  payload="$(emit_bash_payload "test-8a-$form" "$cmd")"
  out="$(run_hook_pretool_payload "$payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
  if [[ "$out" == *'"deny"'* ]]; then
    fail "scenario 8a: safe-redirect read \`$form\` falsely denied — output: $out"
  else
    pass "scenario 8a: safe-redirect read \`$form\` on protected path allowed"
  fi
done

# 8b — real writes on protected path MUST still deny, even adjacent to a
# safe form. `> bar` and `2>err.log` are real file writes; `2>&1` next to
# them must not launder the classification.
for write_cmd in \
  "cat $ACCESS_PATH > /tmp/agb-574-bar" \
  "cat $ACCESS_PATH > /tmp/agb-574-bar 2>&1" \
  "cat $ACCESS_PATH 2>/tmp/agb-574-err"; do
  payload="$(emit_bash_payload "test-8b" "$write_cmd")"
  out="$(run_hook_pretool_payload "$payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
  if [[ "$out" == *'"deny"'* ]] && [[ "$out" == *"system config path"* ]]; then
    pass "scenario 8b: real write denied — \`${write_cmd##* }\`"
  else
    fail "scenario 8b: real write not denied — cmd: $write_cmd / output: $out"
  fi
done

# 8c — path-collision regression (THE r1 substring trap). Naive
# `str.replace('2>/dev/null', '')` strips the substring out of
# `2>/dev/null/extra`, hiding the real write to a path under /dev/null/.
# The token-boundary regex (`_SAFE_REDIRECT_RE`) must keep these as write-
# intent, so a hit on the protected path is denied. r3: variable / command
# substitution suffixes (`$VAR`, `` `cmd` ``) are also non-separators —
# `2>/dev/null$SUFFIX` is a real write to a substituted path, not a
# stderr discard, and must NOT be stripped by the safe-redirect regex.
for trap_cmd in \
  "cat $ACCESS_PATH 2>/dev/null/extra" \
  "cat $ACCESS_PATH 2>/dev/null.bak" \
  "cat $ACCESS_PATH 2>/dev/null\$SUFFIX" \
  "cat $ACCESS_PATH &>/dev/null\$SUFFIX" \
  "cat $ACCESS_PATH 2>/dev/null\`cmd\`"; do
  payload="$(emit_bash_payload "test-8c" "$trap_cmd")"
  out="$(run_hook_pretool_payload "$payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
  if [[ "$out" == *'"deny"'* ]] && [[ "$out" == *"system config path"* ]]; then
    pass "scenario 8c: path-collision write denied — \`${trap_cmd##* }\`"
  else
    fail "scenario 8c: path-collision write not denied — cmd: $trap_cmd / output: $out"
  fi
done

# 8d — compound commands carrying safe forms MUST stay read-intent so the
# protected-path read still passes. Mixes `&&`, `;`, and `|` with the
# three safe-redirect tokens.
for compound_cmd in \
  "cat $ACCESS_PATH && grep x $ACCESS_PATH 2>&1" \
  "cat $ACCESS_PATH; grep x $ACCESS_PATH 2>/dev/null" \
  "cat $ACCESS_PATH 2>/dev/null | grep x 2>&1"; do
  payload="$(emit_bash_payload "test-8d" "$compound_cmd")"
  out="$(run_hook_pretool_payload "$payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
  if [[ "$out" == *'"deny"'* ]]; then
    fail "scenario 8d: compound read falsely denied — cmd: $compound_cmd / output: $out"
  else
    pass "scenario 8d: compound read allowed — \`${compound_cmd}\`"
  fi
done

# --- Scenario 9: Claude OAuth credential file is never tool-readable ----
# Reads of ~/.claude/.credentials.json are blocked even when the generic
# system-config gate would otherwise allow read-intent commands. A leaked
# OAuth access/refresh token in tool output can invalidate every Claude
# session sharing that credential.
cred_cmd="strings /home/ec2-user/.claude/.credentials.json | head"
payload="$(emit_bash_payload "test-9a" "$cred_cmd")"
out="$(run_hook_pretool_payload "$payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$out" == *'"deny"'* ]] && [[ "$out" == *"Claude OAuth credentials are blocked"* ]]; then
  pass "scenario 9a: Bash read of Claude OAuth credential denied"
else
  fail "scenario 9a: Bash read of Claude OAuth credential not denied — output: $out"
fi

read_payload=$(cat <<'JSON'
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Read",
  "tool_use_id": "test-9b",
  "session_id": "test-session-9b",
  "tool_input": {
    "file_path": "/home/ec2-user/.claude/.credentials.json"
  }
}
JSON
)
out="$(run_hook_pretool_payload "$read_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$out" == *'"deny"'* ]] && [[ "$out" == *"Claude OAuth credentials are blocked"* ]]; then
  pass "scenario 9b: Read tool access to Claude OAuth credential denied"
else
  fail "scenario 9b: Read tool access to Claude OAuth credential not denied — output: $out"
fi

payload="$(emit_bash_payload "test-9c" "claude auth status")"
out="$(run_hook_pretool_payload "$payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$out" == *'"deny"'* ]]; then
  fail "scenario 9c: redacted auth-status diagnostic falsely denied — output: $out"
else
  pass "scenario 9c: redacted auth-status diagnostic allowed"
fi

# --- Summary -------------------------------------------------------------
printf '\n[smoke] system-config-gating: %d pass, %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failing scenarios:\n' >&2
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure" >&2
  done
  exit 1
fi
exit 0
