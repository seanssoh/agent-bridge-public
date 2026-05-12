#!/usr/bin/env bash
# claude-token-rotation smoke — registry, per-agent sync, and usage trigger.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi

ROOT="$(mktemp -d -t agb-claude-token-rotation.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

BRIDGE_HOME="$ROOT/home"
BRIDGE_DATA_ROOT="$ROOT/data"
BRIDGE_ROSTER_FILE="$ROOT/agent-roster.sh"
BRIDGE_ROSTER_LOCAL_FILE="$ROOT/agent-roster.local.sh"
BRIDGE_CLAUDE_TOKEN_REGISTRY="$ROOT/runtime/secrets/claude-oauth-tokens.json"
BRIDGE_RUNTIME_SECRETS_DIR="$ROOT/runtime/secrets"
BRIDGE_CLAUDE_TOKEN_SYNC_ALLOW_CURRENT_GROUP_FALLBACK=1
export BRIDGE_HOME BRIDGE_DATA_ROOT BRIDGE_ROSTER_FILE BRIDGE_ROSTER_LOCAL_FILE
export BRIDGE_CLAUDE_TOKEN_REGISTRY BRIDGE_RUNTIME_SECRETS_DIR
export BRIDGE_CLAUDE_TOKEN_SYNC_ALLOW_CURRENT_GROUP_FALLBACK
export BRIDGE_LAYOUT=v2

TOKEN_A="fake-claude-oauth-token-a"
TOKEN_B="fake-claude-oauth-token-b"
TOKEN_C="fake-claude-oauth-token-c"
AGENT="patch"
SECRET_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/credentials/launch-secrets.env"

mkdir -p "$BRIDGE_HOME" "$BRIDGE_DATA_ROOT" "$ROOT/runtime/secrets" "$ROOT/workdir" "$ROOT/bin"
: >"$BRIDGE_ROSTER_FILE"
cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<ROSTER
BRIDGE_ADMIN_AGENT_ID="$AGENT"
bridge_add_agent_id_if_missing "$AGENT"
BRIDGE_AGENT_DESC["$AGENT"]="Patch"
BRIDGE_AGENT_ENGINE["$AGENT"]="claude"
BRIDGE_AGENT_SESSION["$AGENT"]="$AGENT"
BRIDGE_AGENT_WORKDIR["$AGENT"]="$ROOT/workdir"
BRIDGE_AGENT_LAUNCH_CMD["$AGENT"]="claude"
BRIDGE_AGENT_SOURCE["$AGENT"]="static"
ROSTER

cat >"$ROOT/bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
case "${FAKE_CLAUDE_MODE:-ok}" in
  quota)
    printf '%s\n' '{"type":"result","is_error":true,"api_error_status":429,"result":"You'\''ve hit your limit - resets May 13, 3am (UTC)"}'
    exit 1
    ;;
  auth)
    printf '%s\n' '{"type":"result","is_error":true,"api_error_status":401,"result":"unauthorized"}'
    exit 1
    ;;
  *)
    printf '%s\n' '{"type":"result","is_error":false,"result":"OK"}'
    ;;
esac
FAKE_CLAUDE
chmod +x "$ROOT/bin/claude"

pass() {
  printf '[smoke][pass] %s\n' "$1"
}

fail() {
  printf '[smoke][fail] %s\n' "$1" >&2
  exit 1
}

json_assert() {
  "$PYTHON" - "$@" <<'PY'
import json
import sys

label = sys.argv[1]
payload = json.loads(sys.argv[2])
expr = sys.argv[3]
if not eval(expr, {"payload": payload}):
    raise SystemExit(f"{label}: assertion failed: {expr}; payload={payload!r}")
PY
}

ADD_JSON="$(printf '%s' "$TOKEN_A" | "$REPO_ROOT/agent-bridge" auth claude-token add --id first --stdin --activate --sync --json)"
[[ "$ADD_JSON" != *"$TOKEN_A"* ]] || fail "add output leaked token A"
json_assert "add first" "$ADD_JSON" "payload['status'] == 'added' and payload['active_token_id'] == 'first' and payload['sync']['status'] == 'ok'"
grep -Fq "CLAUDE_CODE_OAUTH_TOKEN='$TOKEN_A'" "$SECRET_FILE" || fail "secret file did not receive token A"
pass "add --sync writes active token without leaking it"

ADD_SECOND_JSON="$(printf '%s' "$TOKEN_B" | "$REPO_ROOT/agent-bridge" auth claude-token add --id second --stdin --json)"
[[ "$ADD_SECOND_JSON" != *"$TOKEN_B"* ]] || fail "add output leaked token B"
json_assert "add second" "$ADD_SECOND_JSON" "payload['status'] == 'added' and payload['active_token_id'] == 'first'"
pass "second token registered without activation"

ROTATE_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token rotate --reason smoke --sync --json)"
[[ "$ROTATE_JSON" != *"$TOKEN_A"* && "$ROTATE_JSON" != *"$TOKEN_B"* ]] || fail "rotate output leaked token"
json_assert "rotate" "$ROTATE_JSON" "payload['status'] == 'rotated' and payload['old_active_token_id'] == 'first' and payload['active_token_id'] == 'second' and payload['sync']['status'] == 'ok'"
grep -Fq "CLAUDE_CODE_OAUTH_TOKEN='$TOKEN_B'" "$SECRET_FILE" || fail "secret file did not rotate to token B"
pass "rotate --sync advances launch secret"

DISABLED_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token auto-rotate disable --json)"
json_assert "auto disable" "$DISABLED_JSON" "payload['status'] == 'ok' and payload['auto_rotate_enabled'] is False"
SKIP_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token rotate --if-auto-enabled --sync --json)"
json_assert "auto disabled skip" "$SKIP_JSON" "payload['status'] == 'skipped' and payload['reason'] == 'auto_rotate_disabled'"
ENABLED_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token auto-rotate enable --threshold 99 --json)"
json_assert "auto enable" "$ENABLED_JSON" "payload['status'] == 'ok' and payload['auto_rotate_enabled'] is True and payload['rotation_threshold'] == 99.0"
pass "auto-rotate gate is registry controlled"

ADD_QUOTA_JSON="$(printf '%s' "$TOKEN_C" | "$REPO_ROOT/agent-bridge" auth claude-token add --id quota --stdin --json)"
[[ "$ADD_QUOTA_JSON" != *"$TOKEN_C"* ]] || fail "quota add output leaked token"
CHECK_QUOTA_JSON="$(
  PATH="$ROOT/bin:$PATH" \
  FAKE_CLAUDE_MODE=quota \
  BRIDGE_AUTH_NOW_UTC="2026-05-12T02:00:00+00:00" \
  "$REPO_ROOT/agent-bridge" auth claude-token check quota --disable-on-quota --json
)"
[[ "$CHECK_QUOTA_JSON" != *"$TOKEN_C"* ]] || fail "quota check output leaked token"
json_assert "quota check" "$CHECK_QUOTA_JSON" "payload['status'] == 'quota_limited' and payload['reset_at'] == '2026-05-13T03:00:00+00:00' and payload['token']['enabled'] is False"
RECOVER_NOT_DUE_JSON="$(
  PATH="$ROOT/bin:$PATH" \
  BRIDGE_AUTH_NOW_UTC="2026-05-13T02:59:00+00:00" \
  "$REPO_ROOT/agent-bridge" auth claude-token recover-due --json
)"
json_assert "quota recover not due" "$RECOVER_NOT_DUE_JSON" "payload['status'] == 'skipped' and payload['reason'] == 'no_due_tokens'"
RECOVER_DUE_JSON="$(
  PATH="$ROOT/bin:$PATH" \
  FAKE_CLAUDE_MODE=ok \
  BRIDGE_AUTH_NOW_UTC="2026-05-13T03:00:00+00:00" \
  "$REPO_ROOT/agent-bridge" auth claude-token recover-due --json
)"
json_assert "quota recover due" "$RECOVER_DUE_JSON" "payload['status'] == 'ok' and payload['checked_count'] == 1 and payload['recovered_count'] == 1 and payload['recovered'] == ['quota']"
LIST_AFTER_RECOVER="$("$REPO_ROOT/agent-bridge" auth claude-token list --json)"
json_assert "quota list recovered" "$LIST_AFTER_RECOVER" "next(row for row in payload['tokens'] if row['id'] == 'quota')['enabled'] is True"
pass "quota-limited tokens store reset time and recover automatically when due"

USAGE_ROOT="$ROOT/usage"
USAGE_CACHE="$USAGE_ROOT/claude-usage.json"
USAGE_CODEX="$USAGE_ROOT/codex"
USAGE_STATE="$USAGE_ROOT/state.json"
mkdir -p "$USAGE_CODEX"

write_usage() {
  local weekly="$1"
  local reset="$2"
  cat >"$USAGE_CACHE" <<USAGE
{
  "data": {
    "planName": "Max",
    "fiveHour": 10,
    "sevenDay": $weekly,
    "fiveHourResetAt": "2026-05-11T12:00:00+00:00",
    "sevenDayResetAt": "$reset"
  }
}
USAGE
}

run_monitor() {
  "$PYTHON" "$REPO_ROOT/bridge-usage.py" monitor \
    --claude-usage-cache "$USAGE_CACHE" \
    --codex-sessions-dir "$USAGE_CODEX" \
    --state-file "$USAGE_STATE" \
    --rotation-threshold 99 \
    --json
}

write_usage 98 "2026-05-18T12:00:00+00:00"
MONITOR_98="$(run_monitor)"
json_assert "usage 98" "$MONITOR_98" "payload['rotation_candidates'] == []"

write_usage 99 "2026-05-18T12:00:00+00:00"
MONITOR_99="$(run_monitor)"
json_assert "usage 99" "$MONITOR_99" "len(payload['rotation_candidates']) == 1 and payload['rotation_candidates'][0]['window'] == 'weekly'"
MONITOR_99_AGAIN="$(run_monitor)"
json_assert "usage 99 dedupe" "$MONITOR_99_AGAIN" "payload['rotation_candidates'] == []"

write_usage 99 "2026-05-25T12:00:00+00:00"
MONITOR_99_RESET="$(run_monitor)"
json_assert "usage 99 reset" "$MONITOR_99_RESET" "len(payload['rotation_candidates']) == 1"
pass "usage monitor emits one 99% rotation candidate per reset cycle"

"$REPO_ROOT/agent-bridge" auth claude-token auto-rotate enable --threshold 98 --json >/dev/null
SHELL_USAGE_STATE="$USAGE_ROOT/shell-state.json"
write_usage 98 "2026-06-01T12:00:00+00:00"
SHELL_MONITOR="$(
  BRIDGE_CLAUDE_USAGE_CACHE="$USAGE_CACHE" \
  BRIDGE_CODEX_SESSIONS_DIR="$USAGE_CODEX" \
  BRIDGE_USAGE_MONITOR_STATE_FILE="$SHELL_USAGE_STATE" \
  "$REPO_ROOT/agent-bridge" usage monitor --json
)"
json_assert "usage shell registry threshold" "$SHELL_MONITOR" "len(payload['rotation_candidates']) == 1 and payload['rotation_candidates'][0]['rotation_threshold'] == 98.0"
pass "bridge-usage.sh reads registry rotation threshold"

# PR #799 r2 codex finding 1 — tool-policy.py pretool gate must deny:
#   A. raw Bash text that dereferences $CLAUDE_CODE_OAUTH_TOKEN,
#   B. raw Bash text that mentions the launch-secrets.env filename, and
#   C. raw Bash text or Read input that targets the token registry JSON.
# The credential deny reason is `CLAUDE_CREDENTIAL_DENY_REASON`, which
# contains the literal "Claude OAuth credentials".

run_pretool_bash() {
  # run_pretool_bash <bash command>
  local cmd="$1"
  local payload
  payload=$("$PYTHON" - "$cmd" <<'PY'
import json
import sys
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_use_id": "pr799-r2-smoke",
    "session_id": "pr799-r2-smoke-session",
    "tool_input": {"command": sys.argv[1]},
}))
PY
)
  BRIDGE_AGENT_ID="$AGENT" \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_ADMIN_AGENT_ID="$AGENT" \
    "$PYTHON" "$REPO_ROOT/hooks/tool-policy.py" <<<"$payload"
}

DENY_OUT="$(run_pretool_bash 'printf %s "$CLAUDE_CODE_OAUTH_TOKEN"')"
[[ "$DENY_OUT" == *'"permissionDecision":"deny"'* || "$DENY_OUT" == *'"permissionDecision": "deny"'* ]] || fail "env-deref pretool did not deny: $DENY_OUT"
[[ "$DENY_OUT" == *'Claude OAuth credentials'* ]] || fail "env-deref deny reason missing credential phrase: $DENY_OUT"
pass "pretool denies \$CLAUDE_CODE_OAUTH_TOKEN deref"

DENY_OUT="$(run_pretool_bash "cat $BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json")"
[[ "$DENY_OUT" == *'"permissionDecision":"deny"'* || "$DENY_OUT" == *'"permissionDecision": "deny"'* ]] || fail "registry-path pretool did not deny: $DENY_OUT"
[[ "$DENY_OUT" == *'Claude OAuth credentials'* ]] || fail "registry-path deny reason missing credential phrase: $DENY_OUT"
pass "pretool denies registry JSON read"

DENY_OUT="$(run_pretool_bash 'grep CLAUDE launch-secrets.env')"
[[ "$DENY_OUT" == *'"permissionDecision":"deny"'* || "$DENY_OUT" == *'"permissionDecision": "deny"'* ]] || fail "launch-secrets.env pretool did not deny: $DENY_OUT"
[[ "$DENY_OUT" == *'Claude OAuth credentials'* ]] || fail "launch-secrets.env deny reason missing credential phrase: $DENY_OUT"
pass "pretool denies launch-secrets.env mention"

# PR #799 r2 codex finding 3 — concurrent activate operations must not
# corrupt the registry. With the fcntl-based registry_lock context
# manager, one writer wins fully and the other waits, but neither
# leaves a torn JSON or an undefined active_token_id.

LOCK_REGISTRY="$BRIDGE_CLAUDE_TOKEN_REGISTRY"
LOCK_A_OUT="$ROOT/lock-a.out"
LOCK_B_OUT="$ROOT/lock-b.out"
( "$REPO_ROOT/agent-bridge" auth claude-token activate first --json >"$LOCK_A_OUT" 2>&1 ) &
PID_A=$!
( "$REPO_ROOT/agent-bridge" auth claude-token activate second --json >"$LOCK_B_OUT" 2>&1 ) &
PID_B=$!
wait "$PID_A"
wait "$PID_B"
"$PYTHON" - "$LOCK_REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
active = data.get("active_token_id")
if active not in ("first", "second"):
    raise SystemExit(f"lock-race: unexpected active_token_id={active!r}; registry={data!r}")
ids = {row.get("id") for row in data.get("tokens", []) if isinstance(row, dict)}
if "first" not in ids or "second" not in ids:
    raise SystemExit(f"lock-race: missing tokens; ids={ids!r}")
PY
pass "concurrent activate is lock-serialized (no torn registry)"
