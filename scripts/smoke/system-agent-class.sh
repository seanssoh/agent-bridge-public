#!/usr/bin/env bash
# scripts/smoke/system-agent-class.sh — Issue #539 smoke.
#
# Validates the first-class `system` agent class introduced in #539:
#   1. Roster loader recognizes BRIDGE_AGENT_CLASS and exposes the value
#      via bridge_agent_class (defaulting unknown/missing entries to
#      "user").
#   2. bridge_validate_agent_classes hard-fails on an unknown class.
#   3. hooks/tool-policy.py allows a class=system agent to Read another
#      agent's memory/projects/ tree, audits the access, and continues
#      to deny:
#        - cross-agent Read into a forbidden subpath (state/),
#        - cross-agent Write of any kind (system class is read-only),
#        - cross-agent Read by a default class=user agent.
#
# This smoke uses an isolated BRIDGE_HOME via smoke_setup_bridge_home and
# never touches the operator's live runtime.

set -euo pipefail

SMOKE_NAME="system-agent-class"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "system-agent-class"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

BASH4_BIN="${BASH:-bash}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

# ---------------------------------------------------------------------------
# Step 1 — class roundtrip + default-to-user behavior.
# ---------------------------------------------------------------------------
class_getter_roundtrip() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "alpha"
BRIDGE_AGENT_ENGINE["alpha"]="claude"
BRIDGE_AGENT_SESSION["alpha"]="alpha"
BRIDGE_AGENT_WORKDIR["alpha"]="$BRIDGE_AGENT_HOME_ROOT/alpha"

bridge_add_agent_id_if_missing "beta"
BRIDGE_AGENT_ENGINE["beta"]="claude"
BRIDGE_AGENT_SESSION["beta"]="beta"
BRIDGE_AGENT_WORKDIR["beta"]="$BRIDGE_AGENT_HOME_ROOT/beta"
BRIDGE_AGENT_CLASS["beta"]="system"
EOF

  local out
  out="$(
    "$BASH4_BIN" -c 'repo="$1"; source "$repo/bridge-lib.sh"; bridge_load_roster
      printf "alpha=%s\n" "$(bridge_agent_class alpha)"
      printf "beta=%s\n"  "$(bridge_agent_class beta)"
      printf "missing=%s\n" "$(bridge_agent_class ghost)"
    ' _ "$REPO_ROOT"
  )"

  smoke_assert_contains "$out" "alpha=user"   "alpha defaults to user class"
  smoke_assert_contains "$out" "beta=system"  "beta resolves system class"
  smoke_assert_contains "$out" "missing=user" "unknown agent defaults to user"
}

# ---------------------------------------------------------------------------
# Step 2 — unknown class value is rejected at roster load.
# ---------------------------------------------------------------------------
unknown_class_rejected() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "gamma"
BRIDGE_AGENT_ENGINE["gamma"]="claude"
BRIDGE_AGENT_SESSION["gamma"]="gamma"
BRIDGE_AGENT_WORKDIR["gamma"]="$BRIDGE_AGENT_HOME_ROOT/gamma"
BRIDGE_AGENT_CLASS["gamma"]="admin"
EOF

  local rc=0
  local out
  out="$(
    "$BASH4_BIN" -c 'repo="$1"; source "$repo/bridge-lib.sh"; bridge_load_roster' \
      _ "$REPO_ROOT" 2>&1
  )" || rc=$?

  if (( rc == 0 )); then
    smoke_fail "unknown class 'admin' should have been rejected at roster load"
  fi
  smoke_assert_contains "$out" "unknown agent class 'admin'" "unknown class error message"
  smoke_assert_contains "$out" "gamma" "error names the offending agent"
}

# ---------------------------------------------------------------------------
# Step 3 — tool-policy.py gate scenarios.
#
# We set up two static agents (alpha/user, beta/system) and replay the
# four canonical Pretool payloads through hooks/tool-policy.py. Each
# invocation runs under a BRIDGE_AGENT_ID + BRIDGE_AGENT_CLASS_FOR_HOOK
# env that mirrors the prod export shape from bridge-run.sh. The hook
# emits a one-line JSON deny payload on block; an empty stdout means the
# tool call was allowed.
# ---------------------------------------------------------------------------

# Reset roster maps for the gate scenarios — drop the lingering "admin"
# entry from the rejection test before we re-seed the alpha/beta pair.
reset_roster_for_gate() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "alpha"
BRIDGE_AGENT_ENGINE["alpha"]="claude"
BRIDGE_AGENT_SESSION["alpha"]="alpha"
BRIDGE_AGENT_WORKDIR["alpha"]="$BRIDGE_AGENT_HOME_ROOT/alpha"

bridge_add_agent_id_if_missing "beta"
BRIDGE_AGENT_ENGINE["beta"]="claude"
BRIDGE_AGENT_SESSION["beta"]="beta"
BRIDGE_AGENT_WORKDIR["beta"]="$BRIDGE_AGENT_HOME_ROOT/beta"
BRIDGE_AGENT_CLASS["beta"]="system"
EOF

  # Materialize the agent home dirs so other_agent_homes() (which uses
  # `iterdir()` on $BRIDGE_HOME/agents) sees both peers.
  mkdir -p \
    "$BRIDGE_AGENT_HOME_ROOT/alpha/memory/projects" \
    "$BRIDGE_AGENT_HOME_ROOT/alpha/state" \
    "$BRIDGE_AGENT_HOME_ROOT/beta/memory/projects"
  : >"$BRIDGE_AGENT_HOME_ROOT/alpha/memory/projects/foo.md"
  : >"$BRIDGE_AGENT_HOME_ROOT/alpha/state/foo.db"
}

# Run hooks/tool-policy.py once with the supplied actor class + tool
# payload. Echoes the hook's stdout (empty string when the call was
# allowed; a JSON deny payload when blocked).
run_policy_hook() {
  local actor="$1"
  local actor_class="$2"
  local tool_name="$3"
  local file_path="$4"

  local payload
  payload="$(
    "$PY_BIN" - "$tool_name" "$file_path" <<'PY'
import json
import sys

tool_name, file_path = sys.argv[1], sys.argv[2]
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": tool_name,
    "tool_input": {"file_path": file_path},
    "tool_use_id": "smoke-539",
    "session_id": "smoke-session",
}))
PY
  )"

  BRIDGE_AGENT_ID="$actor" \
  BRIDGE_AGENT_CLASS_FOR_HOOK="$actor_class" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
    "$PY_BIN" "$REPO_ROOT/hooks/tool-policy.py" <<<"$payload"
}

assert_policy_allowed() {
  local context="$1"
  local out="$2"
  if [[ -n "${out//[[:space:]]/}" ]]; then
    smoke_fail "$context: expected ALLOW (empty stdout) but got: $out"
  fi
}

assert_policy_denied() {
  local context="$1"
  local out="$2"
  if [[ -z "${out//[[:space:]]/}" ]]; then
    smoke_fail "$context: expected DENY (deny payload on stdout) but got empty"
  fi
  if [[ "$out" != *"\"permissionDecision\": \"deny\""* ]]; then
    smoke_fail "$context: expected deny permissionDecision; got: $out"
  fi
  if [[ "$out" != *"cross-agent access is blocked"* ]]; then
    smoke_fail "$context: expected cross-agent block reason; got: $out"
  fi
}

count_audit_events() {
  local action="$1"
  if [[ ! -f "$BRIDGE_AUDIT_LOG" ]]; then
    printf '0'
    return 0
  fi
  "$PY_BIN" - "$BRIDGE_AUDIT_LOG" "$action" <<'PY'
import json
import sys
from pathlib import Path

path, action = Path(sys.argv[1]), sys.argv[2]
n = 0
for line in path.read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if row.get("action") == action:
        n += 1
print(n)
PY
}

tool_policy_gate_scenarios() {
  reset_roster_for_gate

  # Truncate the audit log so we can count system_cross_agent_read
  # events from this scenario alone.
  : >"$BRIDGE_AUDIT_LOG"

  local out

  # Scenario A — beta (system) Read of alpha's memory/projects/foo.md → ALLOW.
  out="$(run_policy_hook "beta" "system" "Read" "$BRIDGE_AGENT_HOME_ROOT/alpha/memory/projects/foo.md")"
  assert_policy_allowed "beta system Read of alpha memory/projects/foo.md" "$out"

  # Scenario B — beta (system) Read of alpha's state/foo.db → DENY.
  out="$(run_policy_hook "beta" "system" "Read" "$BRIDGE_AGENT_HOME_ROOT/alpha/state/foo.db")"
  assert_policy_denied "beta system Read of forbidden alpha state/foo.db" "$out"

  # Scenario C — beta (system) Write to alpha's memory/projects/foo.md → DENY.
  # Even though the path is in the system-class read allowlist, Write is
  # not read-intent, so the carve-out must not fire.
  out="$(run_policy_hook "beta" "system" "Write" "$BRIDGE_AGENT_HOME_ROOT/alpha/memory/projects/foo.md")"
  assert_policy_denied "beta system Write to alpha memory/projects/foo.md" "$out"

  # Scenario D — alpha (default user) Read of beta's memory/projects/foo.md → DENY.
  : >"$BRIDGE_AGENT_HOME_ROOT/beta/memory/projects/foo.md"
  out="$(run_policy_hook "alpha" "user" "Read" "$BRIDGE_AGENT_HOME_ROOT/beta/memory/projects/foo.md")"
  assert_policy_denied "alpha user Read of beta memory/projects/foo.md" "$out"

  # Audit ledger — only Scenario A should have emitted the
  # system_cross_agent_read event.
  local count
  count="$(count_audit_events "system_cross_agent_read")"
  smoke_assert_eq "1" "$count" "system_cross_agent_read audit event count"
}

main() {
  smoke_require_cmd "$PY_BIN"
  smoke_run "class getter roundtrip" class_getter_roundtrip
  smoke_run "unknown class rejected at roster load" unknown_class_rejected
  smoke_run "tool-policy.py gate scenarios (#539)" tool_policy_gate_scenarios
  smoke_log "passed"
}

main "$@"
