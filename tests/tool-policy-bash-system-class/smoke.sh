#!/usr/bin/env bash
# tool-policy-bash-system-class smoke — verify the issue #539 follow-up
# carve-out for class=system Bash read-intent peer/shared access.
#
# Background. PR #539/#562 added a Read-tool carve-out so class=system
# agents (e.g. librarian) can read peer memory/{projects,decisions,
# shared}/ and shared/* (excluding shared/private + shared/secrets).
# The Bash code path missed the same carve-out — `if alias in text`
# at the tail of `protected_alias_reason` denied every Bash command
# that named a peer path, even read-intent `ls`/`cat` calls. librarian
# #18510 wedged on this for four days.
#
# This test pins the new behaviour:
#
#   1.  system + read-intent + peer/memory/projects → ALLOW + audit
#   2.  system + read-intent + peer/memory/decisions → ALLOW + audit
#   3.  system + read-intent + shared/notes (non-forbidden) → ALLOW + audit
#   4.  system + read-intent + peer/memory/secrets (outside allowlist)
#       → DENY (allowlist rejects, all_allowed=False)
#   5.  system + read-intent + shared/private/x → DENY (Stage A absolute)
#   6.  system + read-intent + shared/secrets/x → DENY (Stage A absolute)
#   7.  user-class + read-intent + peer/memory/projects → DENY (no carve)
#   8.  system + write-intent (cp) + peer/memory/projects → DENY
#   9.  system + read-intent + here-string smuggle case
#       (`cat .../projects/x <<< "$(cat .../private/secret)"`) → DENY
#  10.  system + read-intent + backtick smuggle → DENY
#  11.  system + read-intent + process-substitution smuggle → DENY
#  12.  system + read-intent + heredoc → DENY (smuggling vector)
#  13.  system + read-intent + multi-stage simple read
#       (`cat .../projects/a && ls .../projects/`) → ALLOW (2 audits)
#  14.  system + read-intent + `--body` skipped path → DENY
#       (text-occurrence proof rejects the unaccounted alias)
#  15.  Track E sanity: idle-marker self-heal (deferred to bash unit
#       below) — just confirms the helper exists with the new
#       fallback path.
#
# Every ALLOW path must produce a `system_cross_agent_read` audit row
# with `tool="Bash"`. Every DENY path must NOT produce that row for
# the request being denied.
#
# Uses an isolated mktemp BRIDGE_HOME — never touches the live install.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi

BRIDGE_HOME="$(mktemp -d -t agb-bash-syscls.XXXXXX)"
export BRIDGE_HOME
# bridge-run.sh exports BRIDGE_AGENT_HOME_ROOT in live agent shells, so
# `agent_home_root()` will ignore BRIDGE_HOME if we leave that var
# dangling. Pin it to the fixture once so every spawned hook sees it.
BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_AGENT_HOME_ROOT
trap 'rm -rf "$BRIDGE_HOME"' EXIT

ADMIN_AGENT="patch"
SYSTEM_AGENT="librarian"
USER_AGENT="huchu"
PEER_AGENT="syrs-derm"

mkdir -p "$BRIDGE_HOME/agents/$ADMIN_AGENT"
mkdir -p "$BRIDGE_HOME/agents/$SYSTEM_AGENT"
mkdir -p "$BRIDGE_HOME/agents/$USER_AGENT"
mkdir -p "$BRIDGE_HOME/agents/$PEER_AGENT/memory/projects"
mkdir -p "$BRIDGE_HOME/agents/$PEER_AGENT/memory/decisions"
mkdir -p "$BRIDGE_HOME/agents/$PEER_AGENT/memory/secrets"
mkdir -p "$BRIDGE_HOME/shared/notes"
mkdir -p "$BRIDGE_HOME/shared/private"
mkdir -p "$BRIDGE_HOME/shared/secrets"
mkdir -p "$BRIDGE_HOME/logs"

PROJECTS_FILE="$BRIDGE_HOME/agents/$PEER_AGENT/memory/projects/x.md"
DECISIONS_FILE="$BRIDGE_HOME/agents/$PEER_AGENT/memory/decisions/y.md"
SECRETS_FILE="$BRIDGE_HOME/agents/$PEER_AGENT/memory/secrets/z.md"
SHARED_NOTES_FILE="$BRIDGE_HOME/shared/notes/foo.md"
SHARED_PRIVATE_FILE="$BRIDGE_HOME/shared/private/p.md"
SHARED_SECRETS_FILE="$BRIDGE_HOME/shared/secrets/s.md"

printf 'projects body\n' >"$PROJECTS_FILE"
printf 'decisions body\n' >"$DECISIONS_FILE"
printf 'secrets body\n' >"$SECRETS_FILE"
printf 'shared notes\n' >"$SHARED_NOTES_FILE"
printf 'shared private\n' >"$SHARED_PRIVATE_FILE"
printf 'shared secrets\n' >"$SHARED_SECRETS_FILE"

AUDIT_LOG="$BRIDGE_HOME/logs/audit.jsonl"

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

run_hook() {
  # run_hook <agent> <class user|system> <bash command>
  local agent="$1"
  local cls="$2"
  local cmd="$3"
  local payload
  payload=$("$PYTHON" - "$cmd" <<'PY'
import json, sys
print(json.dumps({
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "test",
  "session_id": "test-session",
  "tool_input": {"command": sys.argv[1]},
}))
PY
)
  BRIDGE_AGENT_ID="$agent" \
    BRIDGE_AGENT_CLASS_FOR_HOOK="$cls" \
    BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
    BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
    "$PYTHON" "$REPO_ROOT/hooks/tool-policy.py" <<<"$payload"
}

assert_allow() {
  local name="$1"
  local out="$2"
  if [[ -z "$out" ]]; then
    pass "$name: allow (no deny output)"
    return 0
  fi
  # Some allow paths may emit JSON without permissionDecision=deny.
  if [[ "$out" != *'"permissionDecision":"deny"'* ]] && [[ "$out" != *'"permissionDecision": "deny"'* ]]; then
    pass "$name: allow"
    return 0
  fi
  fail "$name: expected allow but got deny — $out"
  return 1
}

assert_deny() {
  local name="$1"
  local out="$2"
  local expect_substr="${3:-cross-agent}"
  if [[ "$out" == *"$expect_substr"* ]]; then
    pass "$name: deny matched '$expect_substr'"
    return 0
  fi
  fail "$name: expected deny containing '$expect_substr' — got: $out"
  return 1
}

audit_has_row() {
  # audit_has_row <action> <expected_target_path_substring> <expected_target_agent>
  local action="$1"
  local path_sub="$2"
  local target_agent="$3"
  [[ -f "$AUDIT_LOG" ]] || return 1
  "$PYTHON" - "$AUDIT_LOG" "$action" "$path_sub" "$target_agent" <<'PY'
import json, sys
log_path, action, path_sub, target_agent = sys.argv[1:5]
with open(log_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("action") != action:
            continue
        detail = row.get("detail") or {}
        if path_sub and path_sub not in str(detail.get("target_path", "")):
            continue
        if detail.get("target_agent") != target_agent:
            continue
        if detail.get("tool") != "Bash":
            continue
        sys.exit(0)
sys.exit(1)
PY
}

audit_count() {
  # audit_count <action> <tool>
  local action="$1"
  local tool="$2"
  [[ -f "$AUDIT_LOG" ]] || { echo 0; return; }
  "$PYTHON" - "$AUDIT_LOG" "$action" "$tool" <<'PY'
import json, sys
log_path, action, tool = sys.argv[1:4]
n = 0
with open(log_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("action") != action:
            continue
        detail = row.get("detail") or {}
        if detail.get("tool") != tool:
            continue
        n += 1
print(n)
PY
}

# --- Scenario 1: system + read + peer/memory/projects -> ALLOW + audit
out="$(run_hook "$SYSTEM_AGENT" system "ls $PROJECTS_FILE" 2>/dev/null)"
assert_allow "scenario 1 (system read peer projects)" "$out"
if audit_has_row "system_cross_agent_read" "$PROJECTS_FILE" "$PEER_AGENT"; then
  pass "scenario 1: audit row present (target_agent=$PEER_AGENT, tool=Bash)"
else
  fail "scenario 1: expected system_cross_agent_read audit row"
fi

# --- Scenario 2: system + read + peer/memory/decisions
out="$(run_hook "$SYSTEM_AGENT" system "cat $DECISIONS_FILE" 2>/dev/null)"
assert_allow "scenario 2 (system read peer decisions)" "$out"
if audit_has_row "system_cross_agent_read" "$DECISIONS_FILE" "$PEER_AGENT"; then
  pass "scenario 2: audit row present"
else
  fail "scenario 2: expected audit row for $DECISIONS_FILE"
fi

# --- Scenario 3: system + read + shared/notes (non-forbidden)
# shared/non-forbidden is broadly readable across classes today; the
# file-tool path emits the system-class audit row when librarian Reads
# the same path. Bash-side audit emission for shared/* reads is
# documented follow-up scope (PR body) — this test pins the no-deny
# behavior but does not assert the audit row.
out="$(run_hook "$SYSTEM_AGENT" system "ls $SHARED_NOTES_FILE" 2>/dev/null)"
assert_allow "scenario 3 (system read shared/notes)" "$out"

# --- Scenario 4: system + read + peer/memory/secrets (not in allowlist)
out="$(run_hook "$SYSTEM_AGENT" system "cat $SECRETS_FILE" 2>/dev/null)"
assert_deny "scenario 4 (system read peer/memory/secrets)" "$out" "cross-agent"

# --- Scenario 5: system + read + shared/private/x (Stage A absolute deny)
out="$(run_hook "$SYSTEM_AGENT" system "cat $SHARED_PRIVATE_FILE" 2>/dev/null)"
assert_deny "scenario 5 (system read shared/private)" "$out" "shared/private"

# --- Scenario 6: system + read + shared/secrets/x (Stage A)
out="$(run_hook "$SYSTEM_AGENT" system "cat $SHARED_SECRETS_FILE" 2>/dev/null)"
assert_deny "scenario 6 (system read shared/secrets)" "$out" "shared/secrets"

# --- Scenario 6a: bare directory `ls .../shared/private` (no trailing slash)
# patch-dev review of 94711d3 caught that the slash-only alias variants in
# `_shared_forbidden_aliases()` let `ls $BRIDGE_HOME/shared/private` slip
# past Stage A. Pin the no-trailing-slash form here.
out="$(run_hook "$SYSTEM_AGENT" system "ls $BRIDGE_HOME/shared/private" 2>/dev/null)"
assert_deny "scenario 6a (bare directory shared/private no trailing slash)" "$out" "shared/private"

# --- Scenario 6b: same regression, secrets root, no trailing slash
out="$(run_hook "$SYSTEM_AGENT" system "ls $BRIDGE_HOME/shared/secrets" 2>/dev/null)"
assert_deny "scenario 6b (bare directory shared/secrets no trailing slash)" "$out" "shared/secrets"

# --- Scenario 7: user-class read on peer/projects -> DENY
out="$(run_hook "$USER_AGENT" user "cat $PROJECTS_FILE" 2>/dev/null)"
assert_deny "scenario 7 (user-class peer read)" "$out" "cross-agent"

# --- Scenario 8: system + write (cp) on peer projects -> DENY
out="$(run_hook "$SYSTEM_AGENT" system "cp $PROJECTS_FILE /tmp/x.md" 2>/dev/null)"
assert_deny "scenario 8 (system write to peer)" "$out" "cross-agent"

# --- Scenario 9: here-string smuggle case (the patch-dev r3 vector)
out="$(run_hook "$SYSTEM_AGENT" system "cat $PROJECTS_FILE <<< \"\$(cat $SHARED_PRIVATE_FILE)\"" 2>/dev/null)"
assert_deny "scenario 9 (heredoc-string + command substitution smuggle)" "$out"

# --- Scenario 10: backtick smuggle
out="$(run_hook "$SYSTEM_AGENT" system 'cat '"$PROJECTS_FILE"' `cat '"$SHARED_PRIVATE_FILE"'`' 2>/dev/null)"
assert_deny "scenario 10 (backtick smuggle)" "$out"

# --- Scenario 11: process substitution smuggle
out="$(run_hook "$SYSTEM_AGENT" system "diff $PROJECTS_FILE <(cat $SHARED_PRIVATE_FILE)" 2>/dev/null)"
assert_deny "scenario 11 (process substitution smuggle)" "$out"

# --- Scenario 12: heredoc — the "<<EOF" embedding gates carve-out
out="$(run_hook "$SYSTEM_AGENT" system "cat $PROJECTS_FILE <<EOF
$SHARED_PRIVATE_FILE
EOF" 2>/dev/null)"
assert_deny "scenario 12 (heredoc smuggle)" "$out"

# --- Scenario 13: multi-stage simple read (no smuggle markers)
before_count="$(audit_count "system_cross_agent_read" "Bash")"
out="$(run_hook "$SYSTEM_AGENT" system "cat $PROJECTS_FILE && ls $DECISIONS_FILE" 2>/dev/null)"
assert_allow "scenario 13 (multi-stage simple peer read)" "$out"
after_count="$(audit_count "system_cross_agent_read" "Bash")"
delta=$((after_count - before_count))
if [[ "$delta" -ge 2 ]]; then
  pass "scenario 13: at least 2 audit rows emitted (delta=$delta)"
else
  fail "scenario 13: expected >=2 audit rows, got delta=$delta"
fi

# --- Scenario 14: --body skipped + alias still in text -> DENY
# `cat --body $peer/projects` skips --body's value via _STRING_PAYLOAD_FLAGS.
# The alias is still in raw text but argv-resolved decision is empty;
# occurrence proof should reject.
out="$(run_hook "$SYSTEM_AGENT" system "cat --body $PROJECTS_FILE" 2>/dev/null)"
assert_deny "scenario 14 (--body skipped value)" "$out" "cross-agent"

# --- Scenario 15: Track E sanity — confirm the helper is wired
if grep -q "bridge_claude_session_try_mark_prompt_ready" \
     "$REPO_ROOT/lib/bridge-channels.sh"; then
  pass "scenario 15: bridge_write_idle_ready_agents falls back to try_mark_prompt_ready"
else
  fail "scenario 15: Track E helper call missing from bridge_write_idle_ready_agents"
fi

# --- Summary
printf '\n[smoke] PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failures:\n' >&2
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f" >&2
  done
  exit 1
fi
exit 0
