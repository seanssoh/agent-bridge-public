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
export BRIDGE_HOME BRIDGE_DATA_ROOT BRIDGE_ROSTER_FILE BRIDGE_ROSTER_LOCAL_FILE
export BRIDGE_CLAUDE_TOKEN_REGISTRY BRIDGE_RUNTIME_SECRETS_DIR
export BRIDGE_LAYOUT=v2

TOKEN_A="fake-claude-oauth-token-a"
TOKEN_B="fake-claude-oauth-token-b"
TOKEN_C="fake-claude-oauth-token-c"
AGENT="patch"
CREDENTIAL_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/home/.claude/.credentials.json"
CLAUDE_CONFIG_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/home/.claude/.claude.json"
CLAUDE_SETTINGS_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/home/.claude/settings.json"
CLAUDE_SETTINGS_EFFECTIVE_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/home/.claude/settings.effective.json"
LEGACY_SECRET_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/credentials/launch-secrets.env"

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
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  printf '%s\n' '{"type":"result","is_error":true,"api_error_status":500,"result":"token env should not be inherited"}'
  exit 1
fi
if [[ "${FAKE_CLAUDE_REQUIRE_CONFIG:-0}" == "1" && -z "${CLAUDE_CONFIG_DIR:-}" ]]; then
  printf '%s\n' '{"type":"result","is_error":true,"api_error_status":401,"result":"missing CLAUDE_CONFIG_DIR"}'
  exit 1
fi
if [[ -n "${CLAUDE_CONFIG_DIR:-}" && ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
  printf '%s\n' '{"type":"result","is_error":true,"api_error_status":401,"result":"missing credential file"}'
  exit 1
fi
case "${FAKE_CLAUDE_MODE:-ok}" in
  structured)
    printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"status":"completed","summary":"OK","findings":[],"actions_taken":[],"needs_human_followup":false,"recommended_next_steps":[],"artifacts":[],"confidence":"high","delivery_intent":"silent"}}'
    ;;
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
"$PYTHON" - "$CREDENTIAL_FILE" "$TOKEN_A" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected = sys.argv[2]
payload = json.loads(path.read_text(encoding="utf-8"))
actual = payload.get("claudeAiOauth", {}).get("accessToken")
if actual != expected:
    raise SystemExit("credential file did not receive token A")
if "refreshToken" in payload.get("claudeAiOauth", {}):
    raise SystemExit("setup-token credential should not invent refreshToken")
PY
"$PYTHON" - "$CLAUDE_CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for key in ("firstStartTime", "migrationVersion", "seenNotifications", "userID"):
    if key not in payload:
        raise SystemExit(f"Claude config bootstrap missing {key}")
if payload.get("hasCompletedOnboarding") is not True:
    raise SystemExit("Claude config bootstrap did not complete onboarding")
projects = payload.get("projects", {})
trusted = [
    key for key, project in projects.items()
    if isinstance(project, dict) and project.get("hasTrustDialogAccepted") is True
]
if not trusted:
    raise SystemExit("Claude config bootstrap did not trust the agent workdir")
if not payload.get("opusProMigrationComplete") or not payload.get("sonnet1m45MigrationComplete"):
    raise SystemExit("Claude config bootstrap did not mark migrations complete")
PY
[[ $? -eq 0 ]] || fail "Claude config bootstrap missing onboarding/trust state"
"$PYTHON" - "$CLAUDE_SETTINGS_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("skipDangerousModePermissionPrompt") is not True:
    raise SystemExit("Claude settings bootstrap did not accept agent bypass-permission launch mode")
PY
[[ $? -eq 0 ]] || fail "Claude settings bootstrap missing bypass-permission state"
[[ -f "$LEGACY_SECRET_FILE" ]] || fail "legacy launch env file with CLAUDE_CONFIG_DIR was not created"
! grep -Fq "CLAUDE_CODE_OAUTH_TOKEN" "$LEGACY_SECRET_FILE" || fail "legacy launch secret still contains token env"
grep -Fq "CLAUDE_CONFIG_DIR='$(dirname "$CREDENTIAL_FILE")'" "$LEGACY_SECRET_FILE" || fail "legacy launch env did not point Claude at per-agent config dir"
pass "add --sync writes Claude credential/config files without leaking token env"

CRON_RUN_DIR="$ROOT/cron-runner-claude-config"
mkdir -p "$CRON_RUN_DIR"
cat >"$CRON_RUN_DIR/payload.txt" <<'PAYLOAD'
Smoke-test cron runner Claude config injection.
PAYLOAD
"$PYTHON" - "$CRON_RUN_DIR" "$ROOT/workdir" <<'PY'
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
workdir = Path(sys.argv[2])
payload = {
    "run_id": "cron-runner-claude-config-smoke",
    "job_name": "cron-runner-claude-config-smoke",
    "family": "smoke",
    "target_agent": "patch",
    "target_engine": "claude",
    "target_workdir": str(workdir),
    "payload_file": str(run_dir / "payload.txt"),
    "result_file": str(run_dir / "result.json"),
    "status_file": str(run_dir / "status.json"),
    "stdout_log": str(run_dir / "stdout.log"),
    "stderr_log": str(run_dir / "stderr.log"),
}
(run_dir / "request.json").write_text(json.dumps(payload), encoding="utf-8")
PY
PATH="$ROOT/bin:$PATH" \
  FAKE_CLAUDE_MODE=structured \
  FAKE_CLAUDE_REQUIRE_CONFIG=1 \
  "$PYTHON" "$REPO_ROOT/bridge-cron-runner.py" run --request-file "$CRON_RUN_DIR/request.json" >/dev/null
"$PYTHON" - "$CRON_RUN_DIR/status.json" "$CRON_RUN_DIR/stdout.log" "$CREDENTIAL_FILE" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if status.get("state") != "success":
    raise SystemExit(f"cron runner did not succeed: {status!r}")
stdout = Path(sys.argv[2]).read_text(encoding="utf-8")
if "missing CLAUDE_CONFIG_DIR" in stdout or "missing credential file" in stdout:
    raise SystemExit(f"cron runner did not inject Claude config: {stdout!r}")
credential_file = Path(sys.argv[3])
if not credential_file.is_file():
    raise SystemExit("credential file missing after cron runner smoke")
PY
pass "cron runner injects per-agent CLAUDE_CONFIG_DIR for claude -p"

ADD_SECOND_JSON="$(printf '%s' "$TOKEN_B" | "$REPO_ROOT/agent-bridge" auth claude-token add --id second --stdin --json)"
[[ "$ADD_SECOND_JSON" != *"$TOKEN_B"* ]] || fail "add output leaked token B"
json_assert "add second" "$ADD_SECOND_JSON" "payload['status'] == 'added' and payload['active_token_id'] == 'first'"
pass "second token registered without activation"

mv "$CLAUDE_SETTINGS_FILE" "$CLAUDE_SETTINGS_EFFECTIVE_FILE"
ln -s "settings.effective.json" "$CLAUDE_SETTINGS_FILE"

ROTATE_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token rotate --reason smoke --sync --json)"
[[ "$ROTATE_JSON" != *"$TOKEN_A"* && "$ROTATE_JSON" != *"$TOKEN_B"* ]] || fail "rotate output leaked token"
json_assert "rotate" "$ROTATE_JSON" "payload['status'] == 'rotated' and payload['old_active_token_id'] == 'first' and payload['active_token_id'] == 'second' and payload['sync']['status'] == 'ok'"
"$PYTHON" - "$CREDENTIAL_FILE" "$TOKEN_B" <<'PY'
import json
import sys
from pathlib import Path

actual = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("claudeAiOauth", {}).get("accessToken")
if actual != sys.argv[2]:
    raise SystemExit("credential file did not rotate to token B")
PY
! grep -Fq "CLAUDE_CODE_OAUTH_TOKEN" "$LEGACY_SECRET_FILE" || fail "legacy launch secret reintroduced token env"
grep -Fq "CLAUDE_CONFIG_DIR='$(dirname "$CREDENTIAL_FILE")'" "$LEGACY_SECRET_FILE" || fail "legacy launch env lost CLAUDE_CONFIG_DIR"
[[ -L "$CLAUDE_SETTINGS_FILE" ]] || fail "Claude settings symlink was replaced during sync"
[[ "$(readlink "$CLAUDE_SETTINGS_FILE")" == "settings.effective.json" ]] || fail "Claude settings symlink target changed during sync"
pass "rotate --sync advances Claude credential file"

# PR #799 r4 codex finding 1 — the bridge-auth.py unchanged-content fast paths
# at ensure_claude_config_file (.claude.json) and ensure_claude_settings_file
# (settings.json) returned without atomic rewrite when the payload matched the
# on-disk content, doing final-path os.chmod/os.chown on a path the agent UID
# can swap to a symlink between check and op. Same TOCTOU symlink-follow class
# as the bash helper r3 removed. r4 drops both fast paths — every sync now
# routes through write_private_file_atomic, which carries the parent-symlink
# check and the chown-before-replace ordering.
#
# Proof: capture the .claude.json and settings.effective.json inodes before and
# after a re-sync. ``os.replace`` always allocates a new inode for the tempfile
# and renames it into place, so the inode MUST rotate even when the JSON
# content is identical. If the dropped fast path were still active, the in-place
# os.chmod/os.chown would leave the inode constant.
#
# The settings.json path on this fixture is a symlink to settings.effective.json
# (set up before the rotate above). The atomic rewrite replaces the symlink's
# TARGET, not the symlink itself, so we stat the resolved target via ``-L``
# (BSD stat on macOS and GNU stat on Linux both honour ``-L`` to dereference).
stat_inode() {
  stat -L -f %i "$1" 2>/dev/null || stat -L -c %i "$1"
}
BEFORE_CLAUDE_INODE="$(stat_inode "$CLAUDE_CONFIG_FILE")"
BEFORE_SETTINGS_INODE="$(stat_inode "$CLAUDE_SETTINGS_FILE")"
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null
AFTER_CLAUDE_INODE="$(stat_inode "$CLAUDE_CONFIG_FILE")"
AFTER_SETTINGS_INODE="$(stat_inode "$CLAUDE_SETTINGS_FILE")"
if [[ "$BEFORE_CLAUDE_INODE" == "$AFTER_CLAUDE_INODE" ]]; then
  fail "r4 unchanged-content fast path: .claude.json inode unchanged after re-sync (before=$BEFORE_CLAUDE_INODE after=$AFTER_CLAUDE_INODE)"
fi
if [[ "$BEFORE_SETTINGS_INODE" == "$AFTER_SETTINGS_INODE" ]]; then
  fail "r4 unchanged-content fast path: settings.json inode unchanged after re-sync (before=$BEFORE_SETTINGS_INODE after=$AFTER_SETTINGS_INODE)"
fi
# The settings.json symlink must still exist and point to the same target —
# atomic rewrite of the resolved target does NOT replace the symlink itself.
[[ -L "$CLAUDE_SETTINGS_FILE" ]] || fail "r4 unchanged-content rewrite replaced settings.json symlink"
[[ "$(readlink "$CLAUDE_SETTINGS_FILE")" == "settings.effective.json" ]] || fail "r4 unchanged-content rewrite changed settings.json symlink target"
pass "unchanged-content sync routes through atomic rewrite (inode rotated for .claude.json + settings.json target)"

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

# PR #799 r2/r3 defense-in-depth — the Path A sync path no longer puts
# Claude OAuth tokens in the tool-inherited environment, but the pretool
# gate must still deny legacy/stale env-token references and the registry:
#   A. raw Bash text that dereferences $CLAUDE_CODE_OAUTH_TOKEN,
#   B. raw Bash text that mentions the legacy launch-secrets.env filename, and
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

# PR #799 r3 codex finding 1 — env-dump verbs revealed the exported
# CLAUDE_CODE_OAUTH_TOKEN without naming the variable under the abandoned
# env-token delivery path. Keep the deny as a legacy/stale-secret guard;
# Path A no longer relies on it for normal Claude OAuth delivery.
for cmd in \
    'env' \
    'env | grep CLAUDE' \
    'printenv' \
    'printenv CLAUDE_CODE_OAUTH_TOKEN' \
    'set' \
    'set | grep ^CLAUDE_' \
    'compgen -e' \
    'declare -p' \
    'declare -x' \
    'typeset -p' \
    'typeset -x' \
    'export -p' \
    'cat /proc/self/environ' \
; do
    DENY_OUT="$(run_pretool_bash "$cmd")"
    [[ "$DENY_OUT" == *'"permissionDecision":"deny"'* || "$DENY_OUT" == *'"permissionDecision": "deny"'* ]] \
        || fail "env-dump pretool did not deny: cmd=$cmd out=$DENY_OUT"
    [[ "$DENY_OUT" == *'Claude OAuth credentials'* ]] \
        || fail "env-dump deny reason missing credential phrase: cmd=$cmd out=$DENY_OUT"
done
# /proc/$$/environ uses a runtime PID — assert via a static-PID variant
DENY_OUT="$(run_pretool_bash 'tr "\0" "\n" < /proc/1234/environ')"
[[ "$DENY_OUT" == *'"permissionDecision":"deny"'* || "$DENY_OUT" == *'"permissionDecision": "deny"'* ]] \
    || fail "procfs-environ pretool did not deny: $DENY_OUT"
[[ "$DENY_OUT" == *'Claude OAuth credentials'* ]] \
    || fail "procfs-environ deny reason missing credential phrase: $DENY_OUT"
pass "pretool denies env-dump verbs (env / printenv / set / compgen -e / declare -p|-x / typeset -p|-x / export -p / /proc/<pid>/environ)"

# PR #799 r3 codex finding 1 — false-positive sanity: legitimate
# commands containing tokens like `set`, `env`, `environment`,
# `setfacl`, `kubectl set image`, etc. must NOT trip the env-dump
# patterns. None of these contains the substrings already covered by
# `_raw_mentions_claude_credentials`, so a deny here would be the new
# `_raw_dumps_process_environment` over-matching.
for cmd in \
    'setfacl -m g:foo:rx /tmp/x' \
    'set -e' \
    'set -o pipefail' \
    'set -x' \
    'kubectl set image deploy/foo bar=baz:1' \
    'git remote set-url origin foo' \
    'environment_var_unrelated=1 ./script.sh' \
    'echo $environment' \
    'declare foo=1' \
    'typeset foo=1' \
    'export FOO=bar' \
; do
    ALLOW_OUT="$(run_pretool_bash "$cmd")"
    if [[ "$ALLOW_OUT" == *'"permissionDecision":"deny"'* || "$ALLOW_OUT" == *'"permissionDecision": "deny"'* ]]; then
        if [[ "$ALLOW_OUT" == *'Claude OAuth credentials'* ]]; then
            fail "false-positive env-dump deny: cmd=$cmd out=$ALLOW_OUT"
        fi
    fi
done
pass "env-dump deny does not over-match setfacl / set -e / kubectl set image / git remote set-url / etc."

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

# PR #799 r3 codex findings 2 + 3 — stale-probe race assertions for
# cmd_check and cmd_recover_due. Both commands run an unlocked
# ``probe_claude_token`` between a locked snapshot and a locked
# persist. If another mutator swaps the row's token value (cmd_add
# --replace, cmd_rotate) or updates the due-state markers during the
# probe window, the persist must DISCARD the stale probe rather than
# overwriting the new state.
#
# Inherent timing: the race needs a sleeping fake `claude` so the
# probe window is observable. Slow CI hosts can skip via
# BRIDGE_SMOKE_FAST=1; the unit-static / integration smoke runs do not
# set that flag, so the assertion stays exercised on CI.
if [[ "${BRIDGE_SMOKE_FAST:-0}" != "1" ]]; then
  SLOW_CLAUDE_DIR="$ROOT/slow-claude"
  mkdir -p "$SLOW_CLAUDE_DIR"
  cat >"$SLOW_CLAUDE_DIR/claude" <<'SLOW_CLAUDE'
#!/usr/bin/env bash
# r3 race-test fake claude — sleeps so a concurrent mutator can swap
# the row's token value or due-state markers before the probe persist
# phase reacquires the lock.
sleep "${SLOW_CLAUDE_SLEEP:-3}"
printf '%s\n' '{"type":"result","is_error":false,"result":"OK"}'
SLOW_CLAUDE
  chmod +x "$SLOW_CLAUDE_DIR/claude"

  # The race tests invoke ``bridge-auth.py`` directly (not via the
  # ``agent-bridge auth`` wrapper). The wrapper's per-call init
  # (sourcing isolation libs, validating layout, etc.) adds variable
  # startup latency that makes the 1-second pre-mutate sleep unreliable
  # — the locked-read snapshot phase had already observed the mutation
  # on slower hosts, defeating the race entirely. Calling the python
  # entry point directly is the contract being tested (the wrapper just
  # exec's ``python3 bridge-auth.py ... recover-due``) and removes the
  # wrapper variance.

  # --- Setup for cmd_check stale-probe skip ---
  RACE_REGISTRY="$ROOT/runtime/secrets/race-check-tokens.json"
  "$PYTHON" "$REPO_ROOT/bridge-auth.py" --registry "$RACE_REGISTRY" \
    add --id race --stdin --json \
    <<<"fake-claude-oauth-token-race-orig" >/dev/null

  CHECK_RACE_OUT="$ROOT/check-race.out"
  (
    PATH="$SLOW_CLAUDE_DIR:$PATH" \
    SLOW_CLAUDE_SLEEP=3 \
    "$PYTHON" "$REPO_ROOT/bridge-auth.py" --registry "$RACE_REGISTRY" \
      check race --enable-on-ok --json \
      >"$CHECK_RACE_OUT" 2>&1
  ) &
  CHECK_PID=$!
  # Give the locked-read phase time to complete, then mutate.
  sleep 1
  "$PYTHON" "$REPO_ROOT/bridge-auth.py" --registry "$RACE_REGISTRY" \
    add --id race --stdin --replace --json \
    <<<"fake-claude-oauth-token-race-NEW" >/dev/null
  wait "$CHECK_PID"
  CHECK_RACE_JSON="$(cat "$CHECK_RACE_OUT")"
  json_assert "cmd_check stale skip" "$CHECK_RACE_JSON" \
    "payload.get('status') == 'skipped' and payload.get('reason') == 'token_replaced'"
  pass "cmd_check discards stale probe when token value was swapped mid-probe"

  # --- Setup for cmd_recover_due stale-probe skip ---
  RECOVER_REGISTRY="$ROOT/runtime/secrets/race-recover-tokens.json"
  "$PYTHON" - "$RECOVER_REGISTRY" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({
    "version": 1,
    "active_token_id": "",
    "auto_rotate_enabled": False,
    "rotation_threshold": 99.0,
    "tokens": [
        {
            "id": "stalecheck",
            "token": "fake-claude-oauth-token-stalecheck",
            "enabled": False,
            "disabled_reason": "quota_limited",
            "disabled_until": "2026-05-12T00:00:00+00:00",
            "next_check_at": "2026-05-12T00:00:00+00:00",
            "created_at": "2026-05-11T00:00:00+00:00",
            "updated_at": "2026-05-11T00:00:00+00:00",
            "last_activated_at": "",
            "note": ""
        }
    ],
    "last_rotation": {}
}, indent=2))
PY
  chmod 600 "$RECOVER_REGISTRY"

  RECOVER_RACE_OUT="$ROOT/recover-race.out"
  (
    PATH="$SLOW_CLAUDE_DIR:$PATH" \
    SLOW_CLAUDE_SLEEP=3 \
    BRIDGE_AUTH_NOW_UTC="2026-05-13T00:00:00+00:00" \
    "$PYTHON" "$REPO_ROOT/bridge-auth.py" --registry "$RECOVER_REGISTRY" \
      recover-due --json \
      >"$RECOVER_RACE_OUT" 2>&1
  ) &
  RECOVER_PID=$!
  # During the probe window, mutate disabled_until on the row.
  sleep 1
  "$PYTHON" - "$RECOVER_REGISTRY" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
for row in data["tokens"]:
    if row["id"] == "stalecheck":
        row["disabled_until"] = "2026-05-14T00:00:00+00:00"
path.write_text(json.dumps(data, indent=2))
PY
  wait "$RECOVER_PID"
  RECOVER_RACE_JSON="$(cat "$RECOVER_RACE_OUT")"
  json_assert "cmd_recover_due stale skip" "$RECOVER_RACE_JSON" \
    "any(s.get('id') == 'stalecheck' and s.get('reason') == 'disabled_until_changed' for s in payload.get('skipped_stale', []))"
  pass "cmd_recover_due discards stale probe when disabled_until changed mid-probe"
else
  printf '[smoke][skip] r3 stale-probe race assertions skipped (BRIDGE_SMOKE_FAST=1)\n'
fi

# PR #799 r2 codex finding 2 — symlink in the agent's `.claude` directory
# must be rejected before any write. The agent owns its own home, so a
# pre-planted symlink to anywhere on disk could trick a privileged write
# into clobbering the symlink target. We register a fresh agent for the
# rejection test so the assertion runs against a clean home (the main
# patch/AGENT flow above has already populated $CREDENTIAL_FILE).

SYM_AGENT="patch-symlink-test"
SYM_AGENT_HOME="$BRIDGE_DATA_ROOT/agents/$SYM_AGENT/home"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<ROSTER_APPEND
bridge_add_agent_id_if_missing "$SYM_AGENT"
BRIDGE_AGENT_DESC["$SYM_AGENT"]="Symlink test"
BRIDGE_AGENT_ENGINE["$SYM_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$SYM_AGENT"]="$SYM_AGENT"
BRIDGE_AGENT_WORKDIR["$SYM_AGENT"]="$ROOT/workdir"
BRIDGE_AGENT_LAUNCH_CMD["$SYM_AGENT"]="claude"
BRIDGE_AGENT_SOURCE["$SYM_AGENT"]="static"
ROSTER_APPEND
mkdir -p "$SYM_AGENT_HOME"
SYM_ATTACK_TARGET="$ROOT/attacker-target"
mkdir -p "$SYM_ATTACK_TARGET"
ln -s "$SYM_ATTACK_TARGET" "$SYM_AGENT_HOME/.claude"

SYM_SYNC_OUT="$ROOT/sym-sync.out"
set +e
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$SYM_AGENT" --json \
  >"$SYM_SYNC_OUT" 2>&1
SYM_SYNC_RC=$?
set -e
SYM_SYNC_TEXT="$(cat "$SYM_SYNC_OUT")"
# Either rc != 0 OR a payload with status != ok and an explicit symlink
# failure is acceptable; the contract is that the credential write does
# NOT happen.
if [[ "$SYM_SYNC_TEXT" != *"symlink"* ]]; then
  fail "symlink-reject did not surface symlink error: rc=$SYM_SYNC_RC out=$SYM_SYNC_TEXT"
fi
# The symlink target must remain empty — no credential file written
# inside it. (The walk through symlink would have created
# $SYM_ATTACK_TARGET/.credentials.json or similar.)
if [[ -e "$SYM_ATTACK_TARGET/.credentials.json" ]]; then
  fail "symlink target was written through: $SYM_ATTACK_TARGET/.credentials.json exists"
fi
pass "symlink in agent .claude/ is rejected before any privileged write"

# PR #799 r2 codex finding 3 — atomic chown: the credential file at its
# final path must be owned by the target UID (never transiently
# root-owned). In the non-isolated smoke harness there is no separate
# isolated UID to chown to, so the assertion is:
#   - the credential file exists at its expected path,
#   - it is owned by the calling UID immediately after sync (i.e. the
#     uid that ran the sync command can read it without a repair step),
#   - mode is 0600.
# When BRIDGE_SMOKE_ATOMIC_CHOWN_REQUIRE_ROOT=1 the harness is being run
# in a privileged isolated-mode driver; assert that the file is NOT
# root-owned (= it was chowned to the agent UID before os.replace).

if [[ ! -f "$CREDENTIAL_FILE" ]]; then
  fail "atomic-chown: credential file missing at $CREDENTIAL_FILE"
fi
CRED_UID="$("$PYTHON" - "$CREDENTIAL_FILE" <<'PY'
import os, sys
print(os.stat(sys.argv[1]).st_uid)
PY
)"
CRED_MODE="$("$PYTHON" - "$CREDENTIAL_FILE" <<'PY'
import os, stat as st, sys
print(oct(st.S_IMODE(os.stat(sys.argv[1]).st_mode)))
PY
)"
SELF_UID="$(id -u)"
if [[ "${BRIDGE_SMOKE_ATOMIC_CHOWN_REQUIRE_ROOT:-0}" == "1" ]]; then
  if [[ "$CRED_UID" == "0" ]]; then
    fail "atomic-chown: isolated-mode credential is still root-owned ($CRED_UID); pre-replace chown did not apply"
  fi
else
  if [[ "$CRED_UID" != "$SELF_UID" ]]; then
    fail "atomic-chown: credential UID=$CRED_UID expected $SELF_UID; rotation is not atomic w.r.t. ownership"
  fi
fi
case "$CRED_MODE" in
  0o600|0o0600) : ;;
  *)
    fail "atomic-chown: credential mode=$CRED_MODE expected 0o600"
    ;;
esac
pass "credential file is owner-correct + mode 0600 at its final path (no transient root-owned window)"

# PR #799 r3 codex finding 1 — the legacy post-sync chown/chmod repair
# helper ``bridge_auth_fix_credential_file_mode`` is a TOCTOU window: it
# walks the final pathnames after Python's ``os.replace`` without
# re-lstat, so the agent UID can swap the final path to a symlink between
# replace and chown, letting the privileged op follow out of the agent
# home. The fix removes the helper entirely (the Python atomic-write
# already produces correct ownership/mode for fresh rotations, and
# legacy stale-state installs are repaired by re-running ``sync``).
# Assert: (a) the function definition is gone from bridge-auth.sh, and
# (b) the sync hot path no longer references it.
if grep -q '^bridge_auth_fix_credential_file_mode\b' "$REPO_ROOT/bridge-auth.sh"; then
  fail "no_post_write_chown_in_sync: bridge_auth_fix_credential_file_mode definition still present"
fi
if grep -q 'bridge_auth_fix_credential_file_mode' "$REPO_ROOT/bridge-auth.sh"; then
  fail "no_post_write_chown_in_sync: bridge_auth_fix_credential_file_mode still referenced in bridge-auth.sh"
fi
pass "post-sync chown TOCTOU helper removed from sync hot path (no bridge_auth_fix_credential_file_mode)"

# PR #799 r5 codex r4 — final-path chmod removed from write_private_file_atomic.
# Codex r4 BLOCKING called out the post-replace ``os.chmod(path, mode)`` as the
# last remaining final-path TOCTOU surface in ``write_private_file_atomic``. The
# fix deletes that line — ``os.replace`` is ``rename(2)`` so the pre-replace
# chmod on the tempfile is preserved through the rename, and no final-path op
# is needed. The AST static check below regresses anyone re-introducing a
# final-path chmod/chown outside the explicit allow-list:
#   - tempfile pre-replace ops inside write_private_file_atomic (tmp_name)
#   - save_registry (controller-owned home, agent-uncontrollable)
#   - probe_claude_token (sandboxed tempfile.TemporaryDirectory)
# Plain shell grep cannot determine the enclosing function for a line, so we
# walk the bridge-auth.py AST and check (call-arg, enclosing-function) pairs.
test_no_post_replace_chmod() {
  local out
  out=$("$PYTHON" - "$REPO_ROOT" <<'PY'
import ast
import sys
from pathlib import Path

repo = Path(sys.argv[1])
src = (repo / "bridge-auth.py").read_text(encoding="utf-8")
tree = ast.parse(src)

# Functions whose entire body is allowed to operate on final paths because
# the caller surface is controller-owned (save_registry) or sandboxed
# (probe_claude_token). write_private_file_atomic is allowed ONLY for
# tempfile ops (tmp_name); a final-path chmod/chown inside it is the very
# r5 regression this assertion guards.
allowed_funcs = {"save_registry", "probe_claude_token"}
wpfa_func = "write_private_file_atomic"

func_spans = []
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef):
        func_spans.append((node.lineno, node.end_lineno or node.lineno, node.name))

def enclosing(lineno):
    matches = [(lo, hi, name) for (lo, hi, name) in func_spans if lo <= lineno <= hi]
    if not matches:
        return None
    # Innermost span = largest lo.
    matches.sort(key=lambda t: t[0])
    return matches[-1][2]

violations = []
for node in ast.walk(tree):
    if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)):
        continue
    if node.func.attr not in ("chmod", "chown"):
        continue
    try:
        arg = ast.unparse(node.args[0])
    except Exception:
        arg = "<complex>"
    # Tempfile-style args are inherently safe.
    if any(tok in arg for tok in ("tmp_name", "tmp_path", "tempfile", "config_path", "path.parent")):
        continue
    fn = enclosing(node.lineno)
    if fn == wpfa_func:
        violations.append(
            f"line {node.lineno}: os.{node.func.attr}({arg}) - final-path op inside write_private_file_atomic (r5 regression)"
        )
    elif fn not in allowed_funcs:
        violations.append(
            f"line {node.lineno}: os.{node.func.attr}({arg}) - outside allow-list (save_registry/probe_claude_token/write_private_file_atomic tempfile); enclosing={fn}"
        )

for v in violations:
    print(v)
PY
)
  if [[ -n "$out" ]]; then
    printf '[smoke][fail] no_post_replace_chmod: bridge-auth.py has unexpected final-path os.chmod/os.chown calls:\n%s\n' "$out" >&2
    exit 1
  fi
  pass "no unguarded final-path os.chmod/os.chown in bridge-auth.py (write_private_file_atomic post-replace removed)"
}

test_no_post_replace_chmod
