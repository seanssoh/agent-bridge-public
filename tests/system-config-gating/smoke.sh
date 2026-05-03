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
