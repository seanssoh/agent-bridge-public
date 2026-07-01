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
BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
BRIDGE_WORKTREE_META_DIR="$BRIDGE_STATE_DIR/worktrees"
BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
BRIDGE_DATA_ROOT="$ROOT/data"
BRIDGE_SHARED_ROOT="$BRIDGE_DATA_ROOT/shared"
BRIDGE_AGENT_ROOT_V2="$BRIDGE_DATA_ROOT/agents"
BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
BRIDGE_CONTROLLER_STATE_ROOT="$BRIDGE_DATA_ROOT/state"
BRIDGE_LAYOUT_MARKER_DIR="$BRIDGE_HOME/state"
BRIDGE_ROSTER_FILE="$ROOT/agent-roster.sh"
BRIDGE_ROSTER_LOCAL_FILE="$ROOT/agent-roster.local.sh"
BRIDGE_CLAUDE_TOKEN_REGISTRY="$ROOT/runtime/secrets/claude-oauth-tokens.json"
BRIDGE_RUNTIME_ROOT="$ROOT/runtime"
BRIDGE_RUNTIME_CREDENTIALS_DIR="$ROOT/runtime/credentials"
BRIDGE_RUNTIME_SECRETS_DIR="$ROOT/runtime/secrets"
BRIDGE_RUNTIME_CONFIG_FILE="$ROOT/runtime/bridge-config.json"
export BRIDGE_HOME BRIDGE_STATE_DIR BRIDGE_ACTIVE_AGENT_DIR BRIDGE_HISTORY_DIR BRIDGE_WORKTREE_META_DIR
export BRIDGE_LOG_DIR BRIDGE_SHARED_DIR BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT
export BRIDGE_AGENT_ROOT_V2 BRIDGE_AGENT_HOME_ROOT BRIDGE_CONTROLLER_STATE_ROOT
export BRIDGE_LAYOUT_MARKER_DIR BRIDGE_ROSTER_FILE BRIDGE_ROSTER_LOCAL_FILE
export BRIDGE_CLAUDE_TOKEN_REGISTRY BRIDGE_RUNTIME_ROOT BRIDGE_RUNTIME_CREDENTIALS_DIR
export BRIDGE_RUNTIME_SECRETS_DIR BRIDGE_RUNTIME_CONFIG_FILE
export BRIDGE_LAYOUT=v2
# #1444 BLOCKING 3: the keychain-free apiKeyHelper feature is Darwin-only, and
# both the settings WRITER (bridge-auth.py) and the launch/cron preflights gate
# on platform. Pin the host platform to Darwin for the default render/disable
# sub-tests so they behave identically on macOS and on the Linux CI runner
# (where native platform.system() == "Linux" would otherwise skip the write).
# A dedicated non-Darwin block below flips this OFF to assert the Linux gate.
export BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin

# #18696: the keychain-free apiKeyHelper is now wired only for a confirmed
# api_key-kind active token (x-api-key contract). This harness exercises the
# apiKeyHelper render / rotate / disable-re-enable / cron / bridge-run preflight
# mechanics, so its rotation pool uses api-key tokens — the kind for which the
# helper path legitimately engages. (OAT-refusal / native-fallback semantics are
# pinned in scripts/smoke/18696-keychain-free-token-kind-guard.sh.)
TOKEN_A="sk-ant-api03-MOCK-not-a-real-token-rotation-a"
TOKEN_B="sk-ant-api03-MOCK-not-a-real-token-rotation-b"
TOKEN_C="sk-ant-api03-MOCK-not-a-real-token-rotation-c"
AGENT="patch"
CREDENTIAL_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/home/.claude/.credentials.json"
CLAUDE_CONFIG_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/home/.claude/.claude.json"
CLAUDE_SETTINGS_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/home/.claude/settings.json"
CLAUDE_SETTINGS_EFFECTIVE_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/home/.claude/settings.effective.json"
LEGACY_SECRET_FILE="$BRIDGE_DATA_ROOT/agents/$AGENT/credentials/launch-secrets.env"
HELPER_SCRIPT="$REPO_ROOT/scripts/claude-oat-api-key-helper.sh"

mkdir -p "$BRIDGE_HOME" "$BRIDGE_STATE_DIR" "$BRIDGE_ACTIVE_AGENT_DIR" "$BRIDGE_HISTORY_DIR" \
  "$BRIDGE_WORKTREE_META_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$BRIDGE_DATA_ROOT" \
  "$BRIDGE_SHARED_ROOT" "$BRIDGE_AGENT_ROOT_V2" "$BRIDGE_AGENT_HOME_ROOT" \
  "$BRIDGE_CONTROLLER_STATE_ROOT" "$BRIDGE_LAYOUT_MARKER_DIR" \
  "$BRIDGE_RUNTIME_CREDENTIALS_DIR" "$ROOT/runtime/secrets" "$ROOT/workdir" "$ROOT/bin"
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
if [[ -n "${FAKE_CLAUDE_MARKER:-}" ]]; then
  : >"$FAKE_CLAUDE_MARKER"
fi
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
if [[ "${FAKE_CLAUDE_REQUIRE_API_KEY_HELPER:-0}" == "1" ]]; then
  if [[ -z "${CLAUDE_CODE_API_KEY_HELPER_TTL_MS:-}" ]]; then
    printf '%s\n' '{"type":"result","is_error":true,"api_error_status":401,"result":"missing apiKeyHelper TTL"}'
    exit 1
  fi
  if [[ -z "${CLAUDE_CONFIG_DIR:-}" || -z "${EXPECTED_API_KEY_HELPER:-}" ]]; then
    printf '%s\n' '{"type":"result","is_error":true,"api_error_status":401,"result":"missing apiKeyHelper inputs"}'
    exit 1
  fi
  if ! python3 - "$CLAUDE_CONFIG_DIR/settings.json" "$EXPECTED_API_KEY_HELPER" >/dev/null 2>&1 <<'PY'
import json
import sys
from pathlib import Path

settings = Path(sys.argv[1])
expected = Path(sys.argv[2]).resolve(strict=False)
payload = json.loads(settings.read_text(encoding="utf-8"))
actual = payload.get("apiKeyHelper")
if not isinstance(actual, str):
    raise SystemExit(1)
if Path(actual).resolve(strict=False) != expected:
    raise SystemExit(1)
PY
  then
    printf '%s\n' '{"type":"result","is_error":true,"api_error_status":401,"result":"bad apiKeyHelper settings"}'
    exit 1
  fi
fi
case "${FAKE_CLAUDE_MODE:-ok}" in
  structured)
    printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"status":"completed","summary":"OK","findings":[],"actions_taken":[],"needs_human_followup":false,"recommended_next_steps":[],"artifacts":[],"confidence":"high","delivery_intent":"silent","forward_target":null,"summary_short":null,"channel_relay":null}}'
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
  local label="$1"
  "$PYTHON" - "$@" <<'PY'
import json
import sys

label = sys.argv[1]
payload = json.loads(sys.argv[2])
expr = sys.argv[3]
if not eval(expr, {"payload": payload}):
    raise SystemExit(f"{label}: assertion failed: {expr}; payload={payload!r}")
PY
  [[ $? -eq 0 ]] || fail "$label assertion failed"
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
if "apiKeyHelper" in payload:
    raise SystemExit("apiKeyHelper rendered while keychain-free auth flag is off")
PY
[[ $? -eq 0 ]] || fail "Claude settings bootstrap missing bypass-permission state"
[[ -f "$LEGACY_SECRET_FILE" ]] || fail "legacy launch env file with CLAUDE_CONFIG_DIR was not created"
! grep -Fq "CLAUDE_CODE_OAUTH_TOKEN" "$LEGACY_SECRET_FILE" || fail "legacy launch secret still contains token env"
grep -Fq "CLAUDE_CONFIG_DIR='$(dirname "$CREDENTIAL_FILE")'" "$LEGACY_SECRET_FILE" || fail "legacy launch env did not point Claude at per-agent config dir"
pass "add --sync writes Claude credential/config files without leaking token env"

"$PYTHON" - "$BRIDGE_RUNTIME_CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({
    "claude_keychain_free_auth": True,
    "claude_api_key_helper_ttl_ms": 60000,
}, indent=2) + "\n", encoding="utf-8")
PY
SYNC_KEYCHAIN_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json)" \
  || fail "keychain-free sync failed"
[[ "$SYNC_KEYCHAIN_JSON" != *"$TOKEN_A"* ]] || fail "keychain-free sync output leaked token"
"$PYTHON" - "$CLAUDE_SETTINGS_FILE" "$HELPER_SCRIPT" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = Path(sys.argv[2]).resolve(strict=False)
actual = payload.get("apiKeyHelper")
if not isinstance(actual, str):
    raise SystemExit("apiKeyHelper missing after enabling keychain-free auth")
if Path(actual).resolve(strict=False) != expected:
    raise SystemExit("apiKeyHelper path mismatch after enabling keychain-free auth")
PY
[[ $? -eq 0 ]] || fail "keychain-free settings render did not add apiKeyHelper"
! grep -Fq "CLAUDE_CODE_OAUTH_TOKEN" "$LEGACY_SECRET_FILE" || fail "keychain-free sync reintroduced token env"
HELPER_TOKEN_BEFORE="$ROOT/helper-before.txt"
"$HELPER_SCRIPT" >"$HELPER_TOKEN_BEFORE" || fail "apiKeyHelper did not return an active token"
"$PYTHON" - "$HELPER_TOKEN_BEFORE" "$TOKEN_A" <<'PY'
import sys
from pathlib import Path

actual = Path(sys.argv[1]).read_text(encoding="utf-8").rstrip("\n")
if actual != sys.argv[2]:
    raise SystemExit("apiKeyHelper did not read the active token")
PY
[[ $? -eq 0 ]] || fail "apiKeyHelper did not read active token"
pass "keychain-free sync renders apiKeyHelper and helper reads active registry token"

# ---------------------------------------------------------------------------
# #1444 BLOCKING 1 (inherited-env canary) — the apiKeyHelper wrapper must NOT
# leak an ambient CLAUDE_CODE_OAUTH_TOKEN into any subprocess it (or the
# bridge-lib.sh it sources) spawns. We seed a fake `dirname` on PATH that
# records whether the token was present in its inherited env, then run the REAL
# helper with a MOCK token set. The wrapper unsets the token (it reads the OAT
# from the locked registry, never from env) BEFORE sourcing bridge-lib.sh, so
# the fake dirname must record ZERO leaks. Mirrors PR #1443's bridge-usage.sh
# scrub proof.
CANARY_BIN="$ROOT/canary-bin"
CANARY_REC="$ROOT/canary-rec"
mkdir -p "$CANARY_BIN" "$CANARY_REC"
# Fake EVERY external child the pre-source path may fork — dirname (SCRIPT_DIR /
# bridge-lib.sh :33), AND mktemp + chmod (the credential file-transit). codex r3
# BLOCKING: a dirname-only canary missed the mktemp/chmod children inheriting the
# token before the unset completed. Each shim records its name on a token leak.
for _canary_tool in dirname mktemp chmod; do
  _canary_real="$(command -v "$_canary_tool")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if printenv CLAUDE_CODE_OAUTH_TOKEN >/dev/null 2>&1; then printf "%%s\\n" "%s" >> %q; fi\n' "$_canary_tool" "$CANARY_REC/leaks.txt"
    printf 'exec %q "$@"\n' "$_canary_real"
  } > "$CANARY_BIN/$_canary_tool"
  chmod +x "$CANARY_BIN/$_canary_tool"
done
unset _canary_tool _canary_real
: >"$CANARY_REC/leaks.txt"
PATH="$CANARY_BIN:$PATH" CLAUDE_CODE_OAUTH_TOKEN="MOCK-CANARY-NOT-A-REAL-TOKEN" \
  "$HELPER_SCRIPT" >/dev/null 2>&1 || true
[[ ! -s "$CANARY_REC/leaks.txt" ]] \
  || fail "BLOCKING 1: apiKeyHelper wrapper leaked CLAUDE_CODE_OAUTH_TOKEN into a child ($(sort -u "$CANARY_REC/leaks.txt" | tr '\n' ' '))"
pass "apiKeyHelper wrapper scrubs the ambient token before any subprocess (inherited-env canary)"

# #1444 BLOCKING 1 (codex Phase-4) — bridge-run.sh sources bridge-lib.sh, whose
# :33 `dirname` runs at source time. On a Darwin keychain-free launch that
# inherited the env token, NONE of bridge-run.sh's startup children may see it.
# bridge-run.sh now captures+unsets the credential vars (STEP A, builtins only,
# UNCONDITIONALLY) BEFORE any external command and before the source, self-re-execs
# to Bash 4+ FIRST (so bridge-lib.sh never re-execs), keeps the values only in
# NON-exported shell vars across the source, and restores them to the child env
# only on the legacy path (mirror of PR #1443 r12). Drive `bridge-run.sh --list`
# keychain-free + Darwin with a MOCK token; the dirname/mktemp/chmod shims must
# record ZERO leak.
: >"$CANARY_REC/leaks.txt"
PATH="$CANARY_BIN:$PATH" \
  BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
  CLAUDE_CODE_OAUTH_TOKEN="MOCK-CANARY-NOT-A-REAL-TOKEN" \
  "$REPO_ROOT/bridge-run.sh" --list >/dev/null 2>&1 || true
[[ ! -s "$CANARY_REC/leaks.txt" ]] \
  || fail "BLOCKING 1 (codex r2/r3): keychain-free Darwin launch leaked the token into a pre-source child ($(sort -u "$CANARY_REC/leaks.txt" | tr '\n' ' '))"
pass "bridge-run.sh scrubs the token before any pre-source child (dirname/mktemp/chmod) on the keychain-free Darwin path"

# #1444 BLOCKING 1 (codex Phase-4 r2) — FORGED-SENTINEL: a prior design gated the
# pre-source scrub on an inherited env-var sentinel, which a same-UID parent could
# pre-export to SKIP the scrub entirely, re-leaking the token into the source-time
# `dirname`. The scrub (STEP A) is now UNCONDITIONAL — it cannot be bypassed — and
# the legacy transit uses a path-var trusted ONLY behind a companion OWNED
# sentinel (mirror of PR #1443). Drive `bridge-run.sh --list` keychain-free +
# Darwin with a MOCK token AND a forged transit sentinel pre-exported (each of:
# the path var alone, the path var WITH a forged OWNED sentinel, and the older
# fd-marker name); the dirname/mktemp/chmod shims must STILL record ZERO leak —
# no forged inbound state bypasses the unconditional scrub.
# Each entry is a space-separated set of forged env assignments handed to `env`.
_bridge_run_forged_cases=(
  "_BRIDGE_RUN_CRED_FILE=/tmp/agb-forged-cred"
  "_BRIDGE_RUN_CRED_FILE=/tmp/agb-forged-cred _BRIDGE_RUN_CRED_OWNED=1"
  "_BRIDGE_RUN_CRED_FD_ACTIVE=1"
)
for _forged in "${_bridge_run_forged_cases[@]}"; do
  : >"$CANARY_REC/leaks.txt"
  # Intentional word-split of the forged env assignment list (handed to `env`).
  # shellcheck disable=SC2086
  PATH="$CANARY_BIN:$PATH" \
    BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
    CLAUDE_CODE_OAUTH_TOKEN="MOCK-CANARY-NOT-A-REAL-TOKEN" \
    env $_forged "$REPO_ROOT/bridge-run.sh" --list >/dev/null 2>&1 || true
  [[ ! -s "$CANARY_REC/leaks.txt" ]] \
    || fail "BLOCKING 1 (codex Phase-4 r2): forged sentinel [$_forged] bypassed the scrub — token leaked into ($(sort -u "$CANARY_REC/leaks.txt" | tr '\n' ' '))"
done
unset _forged _bridge_run_forged_cases
pass "a forged transit sentinel (path-var, path+OWNED, or stale fd marker) does NOT bypass the unconditional pre-source scrub"

# #1444 BLOCKING 1 (codex Phase-4 last-class) — EXPORTED-FUNCTION SHADOW: a
# same-UID caller can `export -f` Bash FUNCTIONS named after ANY command
# bridge-run.sh invokes (printf/read/dirname/mktemp/chmod AND — the names a
# per-`unset -f` list kept missing — `python3`, `uname`, `cat`, `head`, …) so an
# UNQUALIFIED invocation runs the caller's function IN bridge-run.sh's shell,
# where it can read the non-exported credential shell-vars even after the env is
# scrubbed. The codex round-3 miss: the keychain-free gate decision
# `bridge_claude_keychain_free_auth_enabled -> bridge_runtime_config_value` forks
# UNQUALIFIED `python3` (bridge-lib.sh) while the captured secret is still live in
# _bridge_run_tok_oat — but ONLY on the CONFIG-FILE-backed gate path (the env
# `BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1` short-circuit skips
# bridge_runtime_config_value entirely, which is why the env-flag canary below
# missed it). bridge-run.sh now defends at the ROOT: a `bash -p` privileged-mode
# re-exec at the very top strips the WHOLE exported-function class in one shot
# (privileged Bash imports no env functions), so EVERY shadow name — including
# python3/uname — is gone before the secret is captured. This canary exports a
# broad set of malicious shadow functions (printf/read/dirname/mktemp/chmod PLUS
# python3/uname/cat/head/cd/pwd) that record if they EVER observe a credential,
# then runs the REAL `bridge-run.sh --list` keychain-free + Darwin with a MOCK
# token across BOTH gate paths:
#   (a) env-flag path  (BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1; no python3 fork), and
#   (b) CONFIG-FILE path (flag in $BRIDGE_RUNTIME_CONFIG_FILE, env var UNSET — so
#       bridge_runtime_config_value DOES fork python3 with the secret live).
# In both, the shadow functions must record NOTHING (0 invocations) — proving the
# `bash -p` re-exec stripped them, not that python3 specifically was unset.
SHADOW_WRAP="$ROOT/shadow-wrap.sh"
SHADOW_REC="$CANARY_REC/shadow.txt"
{
  printf '#!/usr/bin/env bash\n'
  printf 'REC=%q\n' "$SHADOW_REC"
  printf '_saw() { [[ -n "${_bridge_run_tok_oat:-}" ]] && return 0; local v=CLAUDE_CODE_OAUTH_TOKEN; [[ -n "${!v:-}" ]] && return 0; return 1; }\n'
  printf 'printf()  { _saw && command printf "func:printf\\n"  >>"$REC"; command printf "$@"; }\n'
  printf 'read()    { _saw && command printf "func:read\\n"    >>"$REC"; builtin read "$@"; }\n'
  printf 'dirname() { _saw && command printf "func:dirname\\n" >>"$REC"; command dirname "$@"; }\n'
  printf 'mktemp()  { _saw && command printf "func:mktemp\\n"  >>"$REC"; command mktemp "$@"; }\n'
  printf 'chmod()   { _saw && command printf "func:chmod\\n"   >>"$REC"; command chmod "$@"; }\n'
  printf 'python3() { _saw && command printf "func:python3\\n" >>"$REC"; command python3 "$@"; }\n'
  printf 'uname()   { _saw && command printf "func:uname\\n"   >>"$REC"; command uname "$@"; }\n'
  printf 'cat()     { _saw && command printf "func:cat\\n"     >>"$REC"; command cat "$@"; }\n'
  printf 'head()    { _saw && command printf "func:head\\n"    >>"$REC"; command head "$@"; }\n'
  printf 'export -f printf read dirname mktemp chmod python3 uname cat head _saw\n'
  printf 'exec %q "$@"\n' "$REPO_ROOT/bridge-run.sh"
} > "$SHADOW_WRAP"
chmod +x "$SHADOW_WRAP"

# (a) env-flag gate path (historic case — keep): the env short-circuit means
# bridge_runtime_config_value (and its python3 fork) is NOT reached, but the
# other shadows (printf/read/dirname/mktemp/chmod) still must never fire.
: >"$SHADOW_REC"
BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
  CLAUDE_CODE_OAUTH_TOKEN="MOCK-CANARY-NOT-A-REAL-TOKEN" \
  env _BRIDGE_RUN_CRED_FILE=/tmp/agb-forged-cred _BRIDGE_RUN_CRED_OWNED=1 \
    "$SHADOW_WRAP" --list >/dev/null 2>&1 || true
[[ ! -s "$SHADOW_REC" ]] \
  || fail "BLOCKING 1 (codex Phase-4, env-flag path): an exported shadow function observed a credential ($(sort -u "$SHADOW_REC" | tr '\n' ' '))"

# (b) CONFIG-FILE gate path (codex round-3): UNSET the env flag so the
# keychain-free decision flows through bridge_runtime_config_value -> UNQUALIFIED
# `python3` with the secret live. $BRIDGE_RUNTIME_CONFIG_FILE already holds
# {"claude_keychain_free_auth": true, ...} (written above), and it is exported
# into the env, so the SHADOW_WRAP's `exec` carries it through. The python3()
# shadow MUST still record nothing — the `bash -p` re-exec removed it. Explicitly
# pass BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH= (empty) via `env -u` to guarantee the
# env short-circuit cannot fire even if an outer export leaked in.
[[ -f "$BRIDGE_RUNTIME_CONFIG_FILE" ]] \
  && grep -Fq '"claude_keychain_free_auth": true' "$BRIDGE_RUNTIME_CONFIG_FILE" \
  || fail "config-file canary precondition: runtime config does not enable keychain-free auth"
: >"$SHADOW_REC"
env -u BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
  CLAUDE_CODE_OAUTH_TOKEN="MOCK-CANARY-NOT-A-REAL-TOKEN" \
  "$SHADOW_WRAP" --list >/dev/null 2>&1 || true
[[ ! -s "$SHADOW_REC" ]] \
  || fail "BLOCKING 1 (codex Phase-4 round-3, config-file path): an exported shadow function (e.g. python3 via bridge_runtime_config_value) observed a credential ($(sort -u "$SHADOW_REC" | tr '\n' ' '))"
pass "exported-function shadows (incl. python3/uname via the config-file keychain-free gate) never observe a credential in bridge-run.sh — bash -p strips the whole class"

# #1444 BLOCKING 1 (codex round-3 / parallel #1443) — BASH_ENV / ENV STARTUP-FILE
# HOOK: a same-UID caller can point BASH_ENV (or ENV) at a script that EVERY
# non-interactive non-privileged bash SOURCES at startup, and BASH_XTRACEFD
# redirects `set -x` trace output to a caller-chosen fd. The danger is that any
# child bridge-run.sh forks (the candidate-bash version probe, helper subshells,
# the re-exec'd working shell) could SOURCE the caller's BASH_ENV with the
# ambient token still reachable, leaking it.
#
# bridge-run.sh closes every vector it controls:
#   1. `builtin unset BASH_ENV ENV BASH_XTRACEFD` near the top, before any child
#      THIS script forks.
#   2. The credential is captured + SCRUBBED from the env (STEP A) BEFORE the
#      candidate-bash version probe runs, so the probe child inherits NO token in
#      its env at all; the probe + re-exec also run under `bash -p` (privileged
#      ignores BASH_ENV/ENV + imported functions).
#   3. The re-exec into `bash -p` means the WORKING shell (the one that sources
#      bridge-lib.sh, forks helpers, decides the restore) is privileged — so it
#      and all ITS children never source BASH_ENV regardless of env.
# The ONE sourcing bridge-run.sh cannot prevent is the bash STARTUP of the very
# first `bash bridge-run.sh` process itself: bash reads BASH_ENV before line 1
# executes, so our line-1 `unset` is already too late for that single process.
# That is the deferred "caller controls the initial invocation environment"
# boundary (#1454) — identical in kind to bridge-lib.sh's own startup and to a
# caller shadowing `exec`/`builtin`/`unset`; a caller who controls bridge-run.sh's
# launch env already holds the token. The robust closure is to launch privileged
# (`bash -p bridge-run.sh`), which this canary asserts goes FULLY ABSENT, plus a
# non-privileged sub-case that bounds the residual to exactly that single initial
# startup and proves NO helper/probe/working-shell child amplifies it.
# Resolve a Bash binary for the launch sub-cases below. Prefer the bash running
# this smoke ($BASH — guaranteed Bash 4+ on CI); fall back to PATH. `-p` on (c0)
# needs a real bash that honors privileged mode.
BRIDGE_BASH="${BASH:-$(command -v bash || echo /bin/bash)}"
BASH_ENV_REC="$CANARY_REC/bashenv.txt"
BASH_ENV_FILE="$ROOT/evil-bash-env.sh"
{
  printf '#!/usr/bin/env bash\n'
  # Record the pid + privileged-flag of any bash that sources us WITH the
  # credential visible. At bash STARTUP, BASH_ENV is sourced with $0 = the shell
  # binary (not the script), so we key on the sourcing PROCESS: the unavoidable
  # initial bridge-run.sh startup is a single non-privileged process; any SECOND
  # distinct pid (a deeper probe/helper/working-shell child) would be the real
  # amplification leak. `$-` lets us also confirm the sourcing shell was the
  # non-privileged initial pass (a privileged shell never sources BASH_ENV).
  printf 'if printenv CLAUDE_CODE_OAUTH_TOKEN >/dev/null 2>&1; then printf "pid=%%s flags=%%s\\n" "$$" "$-" >>%q; fi\n' "$BASH_ENV_REC"
} > "$BASH_ENV_FILE"
chmod +x "$BASH_ENV_FILE"

# (c0) PRIVILEGED launch (the hardened invocation contract) — must be FULLY
# ABSENT. Proves bridge-run.sh's re-exec + unset close BASH_ENV end-to-end when
# the initial process is itself privileged.
: >"$BASH_ENV_REC"
env -u BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH \
  PATH="$CANARY_BIN:$PATH" \
  BASH_ENV="$BASH_ENV_FILE" \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
  CLAUDE_CODE_OAUTH_TOKEN="MOCK-CANARY-NOT-A-REAL-TOKEN" \
  "$BRIDGE_BASH" -p "$REPO_ROOT/bridge-run.sh" --list >/dev/null 2>&1 || true
[[ ! -s "$BASH_ENV_REC" ]] \
  || fail "BLOCKING 1 (codex round-3, BASH_ENV privileged launch): a child sourced a hostile BASH_ENV with the token in env ($(sort -u "$BASH_ENV_REC" | tr '\n' ' '))"

# Helper: assert the BASH_ENV sourcings are ONLY the single unavoidable initial
# bridge-run.sh startup process — i.e. NO probe/helper/working-shell child
# amplified the exposure. Distinguisher is the sourcing PROCESS (pid): the
# initial startup is one non-privileged pid; any SECOND distinct pid = a deeper
# child leak. We also assert no PRIVILEGED shell ever sourced it (a privileged
# shell must never source BASH_ENV; if one did, the `-p` hardening is broken).
_assert_bashenv_residual_only_initial() {
  local label="$1" rec="$2"
  local pids
  if grep -q 'flags=[^ ]*p' "$rec" 2>/dev/null; then
    fail "BLOCKING 1 (codex round-3, BASH_ENV $label): a PRIVILEGED shell sourced BASH_ENV ($(sort -u "$rec" | tr '\n' ' ')) — -p hardening broken"
  fi
  pids="$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' "$rec" | sort -u | grep -c . || true)"
  [[ "${pids:-0}" -le 1 ]] \
    || fail "BLOCKING 1 (codex round-3, BASH_ENV $label): BASH_ENV sourced by >1 process ($(sort -u "$rec" | tr '\n' ' ')) — a probe/helper/working-shell child amplified the deferred initial-startup residual"
}

# (c1) env-flag keychain-free path, NON-privileged launch (production `bash
# bridge-run.sh`). The single initial-startup sourcing is the deferred-boundary
# residual; assert NO deeper child amplifies it.
: >"$BASH_ENV_REC"
PATH="$CANARY_BIN:$PATH" \
  BASH_ENV="$BASH_ENV_FILE" \
  BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
  CLAUDE_CODE_OAUTH_TOKEN="MOCK-CANARY-NOT-A-REAL-TOKEN" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-run.sh" --list >/dev/null 2>&1 || true
_assert_bashenv_residual_only_initial "env-flag path" "$BASH_ENV_REC"

# (c2) config-file keychain-free path (env flag UNSET), NON-privileged launch.
: >"$BASH_ENV_REC"
env -u BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH \
  PATH="$CANARY_BIN:$PATH" \
  BASH_ENV="$BASH_ENV_FILE" \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
  CLAUDE_CODE_OAUTH_TOKEN="MOCK-CANARY-NOT-A-REAL-TOKEN" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-run.sh" --list >/dev/null 2>&1 || true
_assert_bashenv_residual_only_initial "config-file path" "$BASH_ENV_REC"
unset -f _assert_bashenv_residual_only_initial
pass "hostile BASH_ENV: ABSENT under privileged launch; under non-privileged launch only the single unavoidable bridge-run.sh startup sources it (deferred #1454) — no probe/helper/working-shell child amplifies it"

# ---------------------------------------------------------------------------
# #1444 BLOCKING 1 — disable/rollback must REMOVE the bridge-managed
# apiKeyHelper so Claude falls back to its normal keychain auth. Before the
# fix, ``ensure_claude_settings_file`` only ADDED the helper on enable and
# never removed it on disable, so flipping the flag off left a stale managed
# helper that exits "disabled" and breaks the intended fallback.
# ---------------------------------------------------------------------------
GATE_HELPER="$REPO_ROOT/scripts/python-helpers/claude-settings-gate-test.py"

# (a) Sanity: the prior enable left the MANAGED helper in settings.json.
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$HELPER_SCRIPT" \
  || fail "precondition: managed apiKeyHelper not present before disable"

# (b) Disable the gate via runtime config, then sync — managed helper must go.
"$PYTHON" "$GATE_HELPER" set-runtime-flag \
  --config "$BRIDGE_RUNTIME_CONFIG_FILE" --key claude_keychain_free_auth --value false \
  || fail "could not flip keychain-free flag off"
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "disable sync failed"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --absent \
  || fail "disable sync did not remove the bridge-managed apiKeyHelper"

# (c) Idempotent: a second disabled sync stays clean (no re-add, no error).
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "second disabled sync failed"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --absent \
  || fail "second disabled sync re-introduced apiKeyHelper (not idempotent)"

# (d) Re-enable + sync re-adds the managed helper (round-trips cleanly).
"$PYTHON" "$GATE_HELPER" set-runtime-flag \
  --config "$BRIDGE_RUNTIME_CONFIG_FILE" --key claude_keychain_free_auth --value true \
  --also-set claude_api_key_helper_ttl_ms=60000 \
  || fail "could not re-enable keychain-free flag"
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "re-enable sync failed"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$HELPER_SCRIPT" \
  || fail "re-enable sync did not re-add the managed apiKeyHelper"
pass "keychain-free disable removes the managed apiKeyHelper, idempotent, re-enable re-adds"

# (e) An operator-owned (non-managed) apiKeyHelper must survive disable —
# the disable cleanup only ever removes OUR managed path, never an operator's
# own helper.
OPERATOR_HELPER="$ROOT/operator-owned-api-key-helper.sh"
: >"$OPERATOR_HELPER"
"$PYTHON" "$GATE_HELPER" set-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --value "$OPERATOR_HELPER" \
  || fail "could not seed operator-owned apiKeyHelper"
"$PYTHON" "$GATE_HELPER" set-runtime-flag \
  --config "$BRIDGE_RUNTIME_CONFIG_FILE" --key claude_keychain_free_auth --value false \
  || fail "could not flip keychain-free flag off for operator-preserve check"
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "operator-preserve disable sync failed"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$OPERATOR_HELPER" \
  || fail "disable clobbered an operator-owned apiKeyHelper"
# A second disabled sync must still preserve it (idempotent on operator value).
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "operator-preserve second disabled sync failed"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$OPERATOR_HELPER" \
  || fail "second disabled sync clobbered the operator-owned apiKeyHelper"
pass "disable preserves an operator-owned (non-managed) apiKeyHelper"

# Restore the enabled gate state so downstream sub-tests see the same
# keychain-free environment the prior block established. Re-enable the flag,
# drop the operator helper override (so the managed path is what renders),
# and run a real sync — leaving settings.json byte-identical to the
# post-enable-sync state the cron-runner sub-test below depends on.
"$PYTHON" "$GATE_HELPER" set-runtime-flag \
  --config "$BRIDGE_RUNTIME_CONFIG_FILE" --key claude_keychain_free_auth --value true \
  --also-set claude_api_key_helper_ttl_ms=60000 \
  || fail "could not restore keychain-free flag after operator-preserve check"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$OPERATOR_HELPER" \
  || fail "operator helper unexpectedly changed before restore sync"
# Remove the operator override so the gate renders the managed helper again.
"$PYTHON" "$GATE_HELPER" set-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --value "$HELPER_SCRIPT" \
  || fail "could not reset apiKeyHelper to managed path before restore sync"
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "restore sync failed"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$HELPER_SCRIPT" \
  || fail "restore sync did not re-render the managed apiKeyHelper"

# ---------------------------------------------------------------------------
# #1444 SHOULD-FIX 4 — an operator's OWN symlink whose target resolves onto the
# managed helper must SURVIVE a disable. The classifier compares the RAW
# (un-dereferenced) value, so only the literal managed path we wrote is removed;
# an operator-introduced symlink is left untouched. Precondition here: gate is
# enabled + Darwin + the managed path is rendered (from the restore sync above).
# ---------------------------------------------------------------------------
OPERATOR_SYMLINK="$ROOT/operator-symlink-to-managed.sh"
rm -f "$OPERATOR_SYMLINK"
ln -s "$HELPER_SCRIPT" "$OPERATOR_SYMLINK"
"$PYTHON" "$GATE_HELPER" set-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --value "$OPERATOR_SYMLINK" \
  || fail "could not seed operator symlink-to-managed apiKeyHelper"
"$PYTHON" "$GATE_HELPER" set-runtime-flag \
  --config "$BRIDGE_RUNTIME_CONFIG_FILE" --key claude_keychain_free_auth --value false \
  || fail "could not flip keychain-free flag off for symlink-preserve check"
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "symlink-preserve disable sync failed"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$OPERATOR_SYMLINK" \
  || fail "disable removed an operator's own symlink-to-managed apiKeyHelper (SHOULD-FIX 4)"
pass "disable preserves an operator's own symlink whose target resolves onto the managed helper"

# Restore: drop the operator symlink value, re-enable the gate, and re-render
# the managed path so the BLOCKING-3 non-Darwin block (and the cron-runner
# sub-test) start from the canonical enabled+managed state.
"$PYTHON" "$GATE_HELPER" set-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --value "$HELPER_SCRIPT" \
  || fail "could not reset apiKeyHelper to managed path before symlink-restore sync"
"$PYTHON" "$GATE_HELPER" set-runtime-flag \
  --config "$BRIDGE_RUNTIME_CONFIG_FILE" --key claude_keychain_free_auth --value true \
  --also-set claude_api_key_helper_ttl_ms=60000 \
  || fail "could not re-enable keychain-free flag after symlink-preserve check"
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "symlink-restore sync failed"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$HELPER_SCRIPT" \
  || fail "symlink-restore sync did not re-render the managed apiKeyHelper"

# ---------------------------------------------------------------------------
# #1444 BLOCKING 3 — the settings WRITER must be Darwin-gated. With the gate
# ENABLED but a NON-Darwin host, sync must NOT render apiKeyHelper, and must
# REMOVE a stale managed value (a controller helper path is wrong for a Linux/
# iso-v2 agent — and not even reachable from the agent UID). On Darwin it still
# renders. Precondition: gate enabled + managed rendered (from the block above).
# ---------------------------------------------------------------------------
# (a) Sanity: under Darwin the managed helper IS present (just rendered above).
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$HELPER_SCRIPT" \
  || fail "BLOCKING 3 precondition: managed apiKeyHelper not present under Darwin"
# (b) Flip the host platform to a NON-Darwin value; the stale managed value must
# be removed on the next sync even though the gate is still enabled.
BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  "$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "non-Darwin sync failed"
BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  "$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
    --settings "$CLAUDE_SETTINGS_FILE" --absent \
  || fail "BLOCKING 3: non-Darwin sync rendered/kept apiKeyHelper (Linux/iso-v2 leak)"
# (c) Idempotent on non-Darwin: a second sync stays clean (no re-add).
BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  "$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "second non-Darwin sync failed"
BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  "$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
    --settings "$CLAUDE_SETTINGS_FILE" --absent \
  || fail "BLOCKING 3: second non-Darwin sync re-introduced apiKeyHelper"
# (d) Back on Darwin the managed helper renders again (round-trips cleanly).
"$REPO_ROOT/agent-bridge" auth claude-token sync --agents "$AGENT" --json >/dev/null \
  || fail "Darwin re-render sync failed"
"$PYTHON" "$GATE_HELPER" assert-apikeyhelper \
  --settings "$CLAUDE_SETTINGS_FILE" --equals "$HELPER_SCRIPT" \
  || fail "BLOCKING 3: Darwin sync did not re-render the managed apiKeyHelper"
pass "settings writer is Darwin-gated: non-Darwin sync renders no apiKeyHelper and strips a stale one"

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
[[ $? -eq 0 ]] || fail "cron runner did not inject Claude config"
pass "cron runner injects per-agent CLAUDE_CONFIG_DIR for claude -p"

CRON_HELPER_RUN_DIR="$ROOT/cron-runner-keychain-free"
mkdir -p "$CRON_HELPER_RUN_DIR"
cat >"$CRON_HELPER_RUN_DIR/payload.txt" <<'PAYLOAD'
Smoke-test cron runner keychain-free apiKeyHelper injection.
PAYLOAD
"$PYTHON" - "$CRON_HELPER_RUN_DIR" "$ROOT/workdir" <<'PY'
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
workdir = Path(sys.argv[2])
payload = {
    "run_id": "cron-runner-keychain-free-smoke",
    "job_name": "cron-runner-keychain-free-smoke",
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
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
  FAKE_CLAUDE_MODE=structured \
  FAKE_CLAUDE_REQUIRE_CONFIG=1 \
  FAKE_CLAUDE_REQUIRE_API_KEY_HELPER=1 \
  EXPECTED_API_KEY_HELPER="$HELPER_SCRIPT" \
  "$PYTHON" "$REPO_ROOT/bridge-cron-runner.py" run --request-file "$CRON_HELPER_RUN_DIR/request.json" >/dev/null
"$PYTHON" - "$CRON_HELPER_RUN_DIR/status.json" "$CRON_HELPER_RUN_DIR/stdout.log" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if status.get("state") != "success":
    raise SystemExit(f"keychain-free cron runner did not succeed: {status!r}")
stdout = Path(sys.argv[2]).read_text(encoding="utf-8")
for needle in ("missing apiKeyHelper TTL", "bad apiKeyHelper settings"):
    if needle in stdout:
        raise SystemExit(f"keychain-free cron runner did not inject helper env: {stdout!r}")
PY
[[ $? -eq 0 ]] || fail "cron runner did not inject keychain-free helper env"
pass "cron runner preflights keychain-free auth and exports apiKeyHelper TTL"

# #1444 BLOCKING 2 — the cron keychain-free preflight subprocess
# (bridge-auth.py api-key-helper --check) must be given an explicit scrubbed
# env=, never inherit the cron runner's ambient os.environ. The canary imports
# the cron runner, plants a MOCK token in os.environ, captures the env= kwarg
# the preflight passes, and asserts the three well-known credential vars are
# stripped (env=None would mean the ambient token leaks in).
"$PYTHON" "$REPO_ROOT/scripts/python-helpers/cron-preflight-env-scrub-canary.py" \
  || fail "BLOCKING 2: cron preflight subprocess did not receive a scrubbed env="
pass "cron keychain-free preflight subprocess env is scrubbed of credential vars"

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
[[ $? -eq 0 ]] || fail "credential file did not rotate to token B"
! grep -Fq "CLAUDE_CODE_OAUTH_TOKEN" "$LEGACY_SECRET_FILE" || fail "legacy launch secret reintroduced token env"
grep -Fq "CLAUDE_CONFIG_DIR='$(dirname "$CREDENTIAL_FILE")'" "$LEGACY_SECRET_FILE" || fail "legacy launch env lost CLAUDE_CONFIG_DIR"
[[ -L "$CLAUDE_SETTINGS_FILE" ]] || fail "Claude settings symlink was replaced during sync"
[[ "$(readlink "$CLAUDE_SETTINGS_FILE")" == "settings.effective.json" ]] || fail "Claude settings symlink target changed during sync"
"$HELPER_SCRIPT" >"$ROOT/helper-after.txt" || fail "apiKeyHelper failed after token rotation"
"$PYTHON" - "$HELPER_TOKEN_BEFORE" "$ROOT/helper-after.txt" "$TOKEN_B" <<'PY'
import sys
from pathlib import Path

before = Path(sys.argv[1]).read_text(encoding="utf-8").rstrip("\n")
after = Path(sys.argv[2]).read_text(encoding="utf-8").rstrip("\n")
expected = sys.argv[3]
if after != expected:
    raise SystemExit("apiKeyHelper did not pick up the rotated active token")
if before == after:
    raise SystemExit("apiKeyHelper returned the same token before and after rotation")
PY
[[ $? -eq 0 ]] || fail "apiKeyHelper did not pick up rotated active token"
pass "rotate --sync advances Claude credential file"

PREFLIGHT_REGISTRY_BACKUP="$ROOT/preflight-registry-backup.json"
cp "$BRIDGE_CLAUDE_TOKEN_REGISTRY" "$PREFLIGHT_REGISTRY_BACKUP"
"$PYTHON" - "$BRIDGE_CLAUDE_TOKEN_REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["active_token_id"] = ""
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
PREFLIGHT_MARKER="$ROOT/fake-claude-launched"
rm -f "$PREFLIGHT_MARKER"
if PATH="$ROOT/bin:$PATH" \
    BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
    FAKE_CLAUDE_MARKER="$PREFLIGHT_MARKER" \
    "$REPO_ROOT/bridge-run.sh" "$AGENT" --once --no-continue \
      >"$ROOT/keychain-free-preflight.out" 2>"$ROOT/keychain-free-preflight.err"; then
  fail "keychain-free preflight allowed launch without an active token"
fi
[[ ! -e "$PREFLIGHT_MARKER" ]] || fail "keychain-free preflight launched claude despite missing token"
grep -Fq "keychain-free auth" "$ROOT/keychain-free-preflight.err" \
  || fail "keychain-free preflight failure did not identify the auth gate"
mv "$PREFLIGHT_REGISTRY_BACKUP" "$BRIDGE_CLAUDE_TOKEN_REGISTRY"
pass "bridge-run keychain-free preflight fails closed before launching claude"

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

# #1789 — rotate must record the rotating-away token's 429 reset window
# (--limited-until) and refuse to rotate INTO a token still inside its own
# window. Without this the daemon round-robins a saturated pool (observed:
# median same-token return 1.2h vs 5h reset windows, 223 rotations/3 days).
# Fixture state here: tokens first+second, active=second.
LIMIT_FUTURE_ISO="$("$PYTHON" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=2)).isoformat(timespec="seconds"))')"
LIMIT_PAST_ISO="$("$PYTHON" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)).isoformat(timespec="seconds"))')"

LIMITED_ROTATE_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token rotate --reason smoke-1789 --limited-until "$LIMIT_FUTURE_ISO" --json)"
[[ "$LIMITED_ROTATE_JSON" != *"$TOKEN_A"* && "$LIMITED_ROTATE_JSON" != *"$TOKEN_B"* ]] || fail "limited rotate output leaked token"
json_assert "limited rotate" "$LIMITED_ROTATE_JSON" "payload['status'] == 'rotated' and payload['old_active_token_id'] == 'second' and payload['active_token_id'] == 'first'"
"$PYTHON" - "$BRIDGE_CLAUDE_TOKEN_REGISTRY" "$LIMIT_FUTURE_ISO" <<'PY'
import json
import sys
from pathlib import Path

registry = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rows = {row.get("id"): row for row in registry.get("tokens", [])}
if rows["second"].get("limited_until") != sys.argv[2]:
    raise SystemExit(f"rotated-away token missing limited_until stamp: {rows['second'].get('limited_until')!r}")
if "limited_until" in rows["first"]:
    raise SystemExit("selected token unexpectedly carries a limited_until stamp")
PY
[[ $? -eq 0 ]] || fail "rotate --limited-until did not stamp the rotated-away token"
pass "rotate --limited-until stamps the rotated-away token's reset window"

POOL_EXHAUSTED_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token rotate --reason smoke-1789-exhausted --json)"
json_assert "pool exhausted" "$POOL_EXHAUSTED_JSON" "payload['status'] == 'skipped' and payload['reason'] == 'all_tokens_limited' and payload['active_token_id'] == 'first' and payload['soonest_reset'] != ''"
"$PYTHON" - "$BRIDGE_CLAUDE_TOKEN_REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

registry = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if registry.get("active_token_id") != "first":
    raise SystemExit(f"all_tokens_limited mutated active token: {registry.get('active_token_id')!r}")
PY
[[ $? -eq 0 ]] || fail "all_tokens_limited skip mutated the active token"
pass "rotate refuses a fully limited pool instead of cycling it"

"$PYTHON" - "$BRIDGE_CLAUDE_TOKEN_REGISTRY" "$LIMIT_PAST_ISO" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
registry = json.loads(path.read_text(encoding="utf-8"))
for row in registry.get("tokens", []):
    if row.get("id") == "second":
        row["limited_until"] = sys.argv[2]
path.write_text(json.dumps(registry, indent=2) + "\n", encoding="utf-8")
PY
EXPIRED_ROTATE_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token rotate --reason smoke-1789-expired --sync --json)"
json_assert "expired stamp rotate" "$EXPIRED_ROTATE_JSON" "payload['status'] == 'rotated' and payload['old_active_token_id'] == 'first' and payload['active_token_id'] == 'second' and payload['sync']['status'] == 'ok'"
"$PYTHON" - "$BRIDGE_CLAUDE_TOKEN_REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

registry = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rows = {row.get("id"): row for row in registry.get("tokens", [])}
if "limited_until" in rows["second"]:
    raise SystemExit("expired limited_until stamp survived activation")
PY
[[ $? -eq 0 ]] || fail "expired limited_until stamp was not cleared on activation"
pass "expired limit window re-admits the token and clears the stale stamp"

# PR #1790 r2 codex finding — explicit `activate` is an operator override and
# must also drop a pending limit-window stamp; otherwise a manually
# reactivated token stays hiddenly ineligible for future rotation until the
# stale timestamp expires.
"$PYTHON" - "$BRIDGE_CLAUDE_TOKEN_REGISTRY" "$LIMIT_FUTURE_ISO" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
registry = json.loads(path.read_text(encoding="utf-8"))
for row in registry.get("tokens", []):
    if row.get("id") == "first":
        row["limited_until"] = sys.argv[2]
path.write_text(json.dumps(registry, indent=2) + "\n", encoding="utf-8")
PY
ACTIVATE_STAMPED_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token activate first --json)"
json_assert "activate stamped" "$ACTIVATE_STAMPED_JSON" "payload['status'] == 'activated' and payload['active_token_id'] == 'first'"
"$PYTHON" - "$BRIDGE_CLAUDE_TOKEN_REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

registry = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rows = {row.get("id"): row for row in registry.get("tokens", [])}
if "limited_until" in rows["first"]:
    raise SystemExit("explicit activate left the limited_until stamp in place")
PY
[[ $? -eq 0 ]] || fail "explicit activate did not clear the limited_until stamp"
ACTIVATE_RESTORE_JSON="$("$REPO_ROOT/agent-bridge" auth claude-token activate second --json)"
json_assert "activate restore" "$ACTIVATE_RESTORE_JSON" "payload['status'] == 'activated' and payload['active_token_id'] == 'second'"
pass "explicit activate clears a pending limit-window stamp (operator override)"

# PR #1790 r3 BLOCKING 1 — the daemon decodes the rotation-status-parse row
# with `IFS=$'\t' read`, and bash treats tab as IFS WHITESPACE: consecutive
# tabs collapse into one delimiter, so any empty column silently shifts every
# column to its right (an all_tokens_limited row put soonest_reset into
# rotation_from). The helper now emits `-` for empty columns and the daemon
# maps `-` back to "". Pin the encode + the bash decode roundtrip.
SENTINEL_ISO="2099-01-02T03:04:05+09:00"
LIMITED_ROW="$("$PYTHON" "$REPO_ROOT/bridge-daemon-helpers.py" rotation-status-parse \
  "{\"status\":\"skipped\",\"reason\":\"all_tokens_limited\",\"active_token_id\":\"first\",\"soonest_reset\":\"$SENTINEL_ISO\"}")"
"$PYTHON" - "$LIMITED_ROW" "$SENTINEL_ISO" <<'PY'
import sys

cols = sys.argv[1].split("\t")
if len(cols) != 6:
    raise SystemExit(f"expected 6 sentinel-encoded columns, got {len(cols)}: {cols!r}")
expect = ["skipped", "all_tokens_limited", "-", "first", "-", sys.argv[2]]
if cols != expect:
    raise SystemExit(f"sentinel encoding mismatch: {cols!r} != {expect!r}")
PY
[[ $? -eq 0 ]] || fail "rotation-status-parse did not sentinel-encode empty columns"
IFS=$'\t' read -r SR_STATUS SR_REASON SR_FROM SR_TO SR_SYNC SR_SOONEST <<<"$LIMITED_ROW"
[[ "$SR_FROM" == "-" ]] && SR_FROM=""
[[ "$SR_SYNC" == "-" ]] && SR_SYNC=""
[[ "$SR_SOONEST" == "-" ]] && SR_SOONEST=""
[[ "$SR_STATUS" == "skipped" && "$SR_REASON" == "all_tokens_limited" && -z "$SR_FROM" && "$SR_TO" == "first" && -z "$SR_SYNC" && "$SR_SOONEST" == "$SENTINEL_ISO" ]] \
  || fail "bash IFS decode misaligned sentinel row: status=$SR_STATUS reason=$SR_REASON from=$SR_FROM to=$SR_TO sync=$SR_SYNC soonest=$SR_SOONEST"
ROTATED_ROW="$("$PYTHON" "$REPO_ROOT/bridge-daemon-helpers.py" rotation-status-parse \
  '{"status":"rotated","old_active_token_id":"a","active_token_id":"b","reason":"usage:weekly:97","sync":{"status":"ok"}}')"
IFS=$'\t' read -r SR_STATUS SR_REASON SR_FROM SR_TO SR_SYNC SR_SOONEST <<<"$ROTATED_ROW"
[[ "$SR_SOONEST" == "-" ]] && SR_SOONEST=""
[[ "$SR_STATUS" == "rotated" && "$SR_FROM" == "a" && "$SR_TO" == "b" && "$SR_SYNC" == "ok" && -z "$SR_SOONEST" ]] \
  || fail "rotated row decode regressed under sentinel encoding: $ROTATED_ROW"
pass "rotation-status-parse sentinel encoding survives the daemon's IFS=tab decode"

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

# ---------------------------------------------------------------------------
# #17927 G1 — parse_reset_at must handle the REAL weekly-429 string
# (``resets Jul 1 at 12pm (Asia/Seoul)`` — abbreviated month, "at" separator,
# NAMED timezone), keep the legacy ``(UTC)``/comma + ``resets in Nh`` forms,
# and gracefully return "" for an unknown zone instead of crashing.
# ---------------------------------------------------------------------------
"$PYTHON" - "$REPO_ROOT/bridge-auth.py" <<'PY'
import importlib.util
import sys
from datetime import datetime, timezone

spec = importlib.util.spec_from_file_location("bridge_auth", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Reference well before every case date so none rolls into next year.
ref = datetime(2026, 1, 1, tzinfo=timezone.utc)

# Legacy forms must be byte-identical.
legacy = {
    "You've hit your limit - resets May 13, 3am (UTC)": "2026-05-13T03:00:00+00:00",
    "resets in 2h 30m": "2026-01-01T02:30:00+00:00",
    "resets in 5h": "2026-01-01T05:00:00+00:00",
}
for text, expect in legacy.items():
    got = mod.parse_reset_at(text, ref)
    if got != expect:
        raise SystemExit(f"legacy parse regressed: {text!r} -> {got!r} (want {expect!r})")

# Named-tz weekly forms — only assert the converted instant when the host
# actually resolves the zone (system tzdata present); otherwise the contract
# is graceful "" (no crash), which we assert in that branch.
named = {
    "You've hit your weekly limit · resets Jul 1 at 12pm (Asia/Seoul)": ("Asia/Seoul", "2026-07-01T03:00:00+00:00"),
    "resets Jul 1, 9:30am (Asia/Kolkata)": ("Asia/Kolkata", "2026-07-01T04:00:00+00:00"),
}
for text, (zone, expect) in named.items():
    got = mod.parse_reset_at(text, ref)
    if mod._resolve_reset_tz(zone) is not None:
        if got != expect:
            raise SystemExit(f"named-tz parse wrong: {text!r} -> {got!r} (want {expect!r})")
    elif got != "":
        raise SystemExit(f"unresolvable zone must yield '' not {got!r} for {text!r}")

# (UTC) still works with the new "at"/abbrev-month tolerant regex.
if mod.parse_reset_at("resets Jul 1 at 12pm (UTC)", ref) != "2026-07-01T12:00:00+00:00":
    raise SystemExit("named-tz regex broke the (UTC) at-separator form")

# #17927 codex r1: the day/hour separator must be REQUIRED, not fully optional.
# A malformed string with no separator (``resets Jul 112pm``) must REJECT, not
# over-match as ``Jul 11`` + ``2pm``. Bare-space and comma-no-space stay valid.
if mod.parse_reset_at("resets Jul 112pm (UTC)", ref) != "":
    raise SystemExit("missing day/hour separator must reject, not over-match")
if mod.parse_reset_at("resets Jul 1 12pm (UTC)", ref) != "2026-07-01T12:00:00+00:00":
    raise SystemExit("bare-space day/hour separator must still parse")
if mod.parse_reset_at("resets Jul 1,12pm (UTC)", ref) != "2026-07-01T12:00:00+00:00":
    raise SystemExit("comma-no-space day/hour separator must still parse")

# Unknown/bogus zone -> graceful "" (never raises).
for bad in ("resets Jul 1 at 12pm (Mars/Phobos)", "resets Jul 1 at 12pm (Not_A_Zone)"):
    if mod.parse_reset_at(bad, ref) != "":
        raise SystemExit(f"unknown tz should yield '' for {bad!r}")

# #2204: malformed date-anchored weekly strings must FAIL CLOSED ("") instead of
# raising out of the probe, exactly like the bare-clock malformed set below.
# ``Jul 32``/``Jul 0`` trip the static day guard; ``Feb 30`` overflows the month
# specifically and is caught by the try/except (a static bound cannot reject it).
for bad in ("resets Jul 32 at 12pm (UTC)", "resets Feb 30 at 12pm (UTC)",
            "resets Jul 1 at 13pm (UTC)", "resets Jul 1 at 12:60pm (UTC)",
            "resets Jul 0 at 12pm (UTC)"):
    if mod.parse_reset_at(bad, ref) != "":
        raise SystemExit(f"malformed date-anchored weekly must yield '' (no raise) for {bad!r}")

# Session-limit (5h) 429 carries a BARE clock with no date —
# ``You've hit your session limit · resets 12:10pm (Asia/Seoul)``. The
# date-anchored weekly regex never matches it (a digit right after ``resets``
# fails its month-name group), so before this branch reset_at came back "" and
# a ~hours session cap was indistinguishable from a multi-day weekly cap.
# Resolve to the NEXT occurrence of the wall-clock in the named zone. Guard the
# zone-dependent asserts on tzdata availability (same contract as the weekly
# named-tz cases above).
if mod._resolve_reset_tz("Asia/Seoul") is not None:
    seoul_cases = {
        # 12:10pm KST = 03:10 UTC; ref(00:00Z) is earlier the same Seoul day -> today.
        "resets 12:10pm (Asia/Seoul)": "2026-01-01T03:10:00+00:00",
        "You've hit your session limit · resets 12:10pm (Asia/Seoul)": "2026-01-01T03:10:00+00:00",
    }
    for text, expect in seoul_cases.items():
        got = mod.parse_reset_at(text, ref)
        if got != expect:
            raise SystemExit(f"bare-clock session parse wrong: {text!r} -> {got!r} (want {expect!r})")
    # Late-night WRAP: at 2026-01-02 05:00 KST the next 1am is the 3rd (KST) =
    # 2026-01-02T16:00Z. Proves the in-zone next-day roll (not a UTC "today").
    ref_wrap = datetime(2026, 1, 1, 20, 0, tzinfo=timezone.utc)
    got = mod.parse_reset_at("resets 1am (Asia/Seoul)", ref_wrap)
    if got != "2026-01-02T16:00:00+00:00":
        raise SystemExit(f"bare-clock late-night wrap wrong: {got!r} (want 2026-01-02T16:00:00+00:00)")

# (UTC) bare clock, no minutes, resolves the same way (UTC always resolvable).
if mod.parse_reset_at("resets 3am (UTC)", ref) != "2026-01-01T03:00:00+00:00":
    raise SystemExit("bare-clock (UTC) form must parse")

# A bare clock with NO zone parens must REJECT (no over-match on a stray time).
if mod.parse_reset_at("resets 12:10pm", ref) != "":
    raise SystemExit("bare clock without a zone must reject")
# Unknown zone on a bare clock -> graceful "" (never raises).
if mod.parse_reset_at("resets 12:10pm (Mars/Phobos)", ref) != "":
    raise SystemExit("bare-clock unknown tz should yield ''")

# Real session-message SHAPE (prose + middle-dot + bare clock) must parse on
# ANY host — use (UTC) so this asserts the regex/anchor unconditionally, even
# where Asia/Seoul tzdata is absent and the named cases above were skipped.
if mod.parse_reset_at("You've hit your session limit · resets 12:10pm (UTC)", ref) != "2026-01-01T12:10:00+00:00":
    raise SystemExit("real session-limit prose shape must parse via (UTC)")

# Malformed bare clocks must FAIL CLOSED ("") instead of raising out of the
# probe — parse_reset_at returns "" for anything it cannot turn into a real
# instant (mirrors the unknown-zone contract).
for bad in ("resets 13pm (UTC)", "resets 12:60pm (UTC)", "resets 99:99pm (UTC)"):
    if mod.parse_reset_at(bad, ref) != "":
        raise SystemExit(f"malformed bare clock must yield '' (no raise) for {bad!r}")
PY
[[ $? -eq 0 ]] || fail "parse_reset_at named-tz / fallback unit cases failed (#17927 G1)"
pass "parse_reset_at parses named-tz weekly + bare-clock session resets, keeps legacy forms, falls back on unknown tz"

# ---------------------------------------------------------------------------
# #17927 G1/G2 — mark-quota stamps limited_until from the parsed reset, and
# recover-due is CLOCK-authoritative: a token whose window is still open stays
# disabled even when the probe says available (over-recovery thrash killed),
# and a token whose window has passed re-enables even when the probe FAILS
# (probe-optional / clock-trust). Legacy no-stamp rows keep probe behavior.
# ---------------------------------------------------------------------------

# G1 stamping: mark-quota with a parsed reset now writes limited_until too.
MARK_REGISTRY="$ROOT/runtime/secrets/mark-quota-stamp-tokens.json"
"$PYTHON" "$REPO_ROOT/bridge-auth.py" --registry "$MARK_REGISTRY" \
  add --id m --stdin --json <<<"fake-claude-oauth-token-m" >/dev/null
MARK_JSON="$("$PYTHON" "$REPO_ROOT/bridge-auth.py" --registry "$MARK_REGISTRY" \
  mark-quota m --reset-at "2026-07-01T03:00:00+00:00" --json)"
json_assert "mark-quota stamps" "$MARK_JSON" \
  "payload['status'] == 'quota_limited' and payload['reset_at'] == '2026-07-01T03:00:00+00:00'"
"$PYTHON" - "$MARK_REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

rows = {r["id"]: r for r in json.loads(Path(sys.argv[1]).read_text())["tokens"]}
row = rows["m"]
if row.get("limited_until") != "2026-07-01T03:00:00+00:00":
    raise SystemExit(f"mark-quota did not stamp limited_until: {row.get('limited_until')!r}")
if row.get("disabled_until") != "2026-07-01T03:00:00+00:00":
    raise SystemExit("mark-quota dropped disabled_until")
PY
[[ $? -eq 0 ]] || fail "mark-quota did not stamp limited_until from the parsed reset (#17927 G1)"
pass "mark-quota stamps limited_until from the parsed reset window (#17927 G1)"

CLOCK_REGISTRY="$ROOT/runtime/secrets/clock-recovery-tokens.json"
G2_FUTURE_ISO="$("$PYTHON" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=6)).isoformat(timespec="seconds"))')"
G2_PAST_ISO="$("$PYTHON" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=6)).isoformat(timespec="seconds"))')"

# Seed a disabled quota_limited row. $1 = limited_until, $2 = disabled/next gate.
seed_clock_registry() {
  "$PYTHON" - "$CLOCK_REGISTRY" "$1" "$2" <<'PY'
import json
import sys
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
            "id": "capped",
            "token": "fake-claude-oauth-token-capped",
            "enabled": False,
            "disabled_reason": "quota_limited",
            "limited_until": sys.argv[2],
            "disabled_until": sys.argv[3],
            "next_check_at": sys.argv[3],
            "created_at": "2026-05-11T00:00:00+00:00",
            "updated_at": "2026-05-11T00:00:00+00:00",
        }
    ],
    "last_rotation": {},
}, indent=2) + "\n", encoding="utf-8")
PY
  chmod 600 "$CLOCK_REGISTRY"
}

# Case A — window OPEN (limited_until future) but DUE by next_check_at; the
# probe is stubbed to SUCCEED. Clock wins: token stays DISABLED.
seed_clock_registry "$G2_FUTURE_ISO" "$G2_PAST_ISO"
RECOVER_OPEN_JSON="$(
  PATH="$ROOT/bin:$PATH" FAKE_CLAUDE_MODE=ok \
    "$PYTHON" "$REPO_ROOT/bridge-auth.py" --registry "$CLOCK_REGISTRY" recover-due --json
)"
json_assert "clock window-open stays disabled" "$RECOVER_OPEN_JSON" \
  "payload['checked_count'] == 1 and payload['recovered_count'] == 0 and payload['recovered'] == [] and payload['still_disabled_count'] == 1"
"$PYTHON" - "$CLOCK_REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

row = {r["id"]: r for r in json.loads(Path(sys.argv[1]).read_text())["tokens"]}["capped"]
if row.get("enabled") is not False:
    raise SystemExit("window-open token was prematurely re-enabled despite a passing probe")
PY
[[ $? -eq 0 ]] || fail "clock window-open token re-enabled on probe (#17927 G2 over-recovery not killed)"
pass "recover-due keeps a future-limited token disabled even when the probe says available (#17927 G2)"

# Case B — window PASSED (limited_until past), probe stubbed to FAIL (auth).
# Clock wins: token re-enables WITHOUT requiring an 'available' probe.
seed_clock_registry "$G2_PAST_ISO" "$G2_PAST_ISO"
RECOVER_PASSED_JSON="$(
  PATH="$ROOT/bin:$PATH" FAKE_CLAUDE_MODE=auth \
    "$PYTHON" "$REPO_ROOT/bridge-auth.py" --registry "$CLOCK_REGISTRY" recover-due --json
)"
json_assert "clock window-passed re-enables" "$RECOVER_PASSED_JSON" \
  "payload['checked_count'] == 1 and payload['recovered_count'] == 1 and payload['recovered'] == ['capped'] and payload['still_disabled_count'] == 0"
"$PYTHON" - "$CLOCK_REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

row = {r["id"]: r for r in json.loads(Path(sys.argv[1]).read_text())["tokens"]}["capped"]
if row.get("enabled") is not True:
    raise SystemExit("window-passed token not re-enabled despite the clock (probe-optional broken)")
if "limited_until" in row:
    raise SystemExit("re-enabled token kept a stale limited_until stamp")
PY
[[ $? -eq 0 ]] || fail "clock window-passed token not re-enabled with a failing probe (#17927 G2)"
pass "recover-due re-enables a window-passed token even when the probe fails (#17927 G2 clock-trust)"

# Case C — legacy/orphan row with NO reset stamp keeps probe-driven behavior:
# a passing probe re-enables it (no regression for pre-#17927 installs).
"$PYTHON" - "$CLOCK_REGISTRY" "$G2_PAST_ISO" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
for row in data["tokens"]:
    if row["id"] == "capped":
        row["enabled"] = False
        row["disabled_reason"] = "quota_limited"
        row.pop("limited_until", None)
        row.pop("disabled_until", None)
        row["next_check_at"] = sys.argv[2]  # due, but no reset stamp
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
chmod 600 "$CLOCK_REGISTRY"
RECOVER_LEGACY_JSON="$(
  PATH="$ROOT/bin:$PATH" FAKE_CLAUDE_MODE=ok \
    "$PYTHON" "$REPO_ROOT/bridge-auth.py" --registry "$CLOCK_REGISTRY" recover-due --json
)"
json_assert "legacy no-stamp probe recovers" "$RECOVER_LEGACY_JSON" \
  "payload['checked_count'] == 1 and payload['recovered_count'] == 1 and payload['recovered'] == ['capped']"
pass "recover-due preserves probe-driven recovery for a legacy row with no reset stamp (#17927 G2)"

# Case D — a clock-elapsed row must recover even when the probe RAISES a hard
# error (e.g. an OSError during temp-config setup), not just a soft failure.
# probe_claude_token only catches Timeout/FileNotFound; an uncaught exception
# would otherwise abort the whole sweep and strand every due token. Drive
# cmd_recover_due directly with the probe monkeypatched to raise.
"$PYTHON" - "$REPO_ROOT/bridge-auth.py" "$ROOT/runtime/secrets/probe-raise-tokens.json" <<'PY'
import argparse
import importlib.util
import io
import json
import sys
from contextlib import redirect_stdout
from pathlib import Path

spec = importlib.util.spec_from_file_location("bridge_auth", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

reg = Path(sys.argv[2])
reg.parent.mkdir(parents=True, exist_ok=True)
reg.write_text(json.dumps({
    "version": 1,
    "active_token_id": "",
    "auto_rotate_enabled": False,
    "rotation_threshold": 99.0,
    "tokens": [{
        "id": "capped",
        "token": "fake-claude-oauth-token-capped-raise",
        "enabled": False,
        "disabled_reason": "quota_limited",
        "limited_until": "2020-01-01T00:00:00+00:00",
        "disabled_until": "2020-01-01T00:00:00+00:00",
        "next_check_at": "2020-01-01T00:00:00+00:00",
        "created_at": "2020-01-01T00:00:00+00:00",
        "updated_at": "2020-01-01T00:00:00+00:00",
    }],
    "last_rotation": {},
}, indent=2) + "\n", encoding="utf-8")
reg.chmod(0o600)


def boom(token, timeout):
    raise OSError("simulated temp-config setup failure")


mod.probe_claude_token = boom

buf = io.StringIO()
with redirect_stdout(buf):
    rc = mod.cmd_recover_due(argparse.Namespace(
        registry=str(reg), retry_seconds=1800, timeout=1, json=True,
    ))
payload = json.loads(buf.getvalue())
if rc != 0:
    raise SystemExit(f"recover-due aborted (rc={rc}) when the probe raised: {payload!r}")
if payload.get("recovered") != ["capped"] or payload.get("recovered_count") != 1:
    raise SystemExit(f"clock-elapsed row not recovered when probe raised: {payload!r}")
row = {r["id"]: r for r in json.loads(reg.read_text())["tokens"]}["capped"]
if row.get("enabled") is not True:
    raise SystemExit("row left disabled after a raising-probe clock recovery")
PY
[[ $? -eq 0 ]] || fail "recover-due aborted instead of clock-recovering when the probe raised (#17927 G2)"
pass "recover-due re-enables a window-passed token even when the probe RAISES a hard error (#17927 G2)"

USAGE_ROOT="$ROOT/usage"
USAGE_CACHE="$USAGE_ROOT/claude-usage.json"
USAGE_CODEX="$USAGE_ROOT/codex"
USAGE_STATE="$USAGE_ROOT/state.json"
mkdir -p "$USAGE_CODEX"

write_usage() {
  local weekly="$1"
  local reset="$2"
  local five_hour="${3:-10}"
  cat >"$USAGE_CACHE" <<USAGE
{
  "data": {
    "planName": "Max",
    "fiveHour": $five_hour,
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

write_usage 94 "2026-05-18T12:00:00+00:00"
MONITOR_94="$(run_monitor)"
json_assert "usage 94" "$MONITOR_94" "payload['rotation_candidates'] == []"

write_usage 99 "2026-05-18T12:00:00+00:00"
MONITOR_99="$(run_monitor)"
json_assert "usage 99" "$MONITOR_99" "len(payload['rotation_candidates']) == 1 and payload['rotation_candidates'][0]['window'] == 'weekly'"
MONITOR_99_AGAIN="$(run_monitor)"
json_assert "usage 99 dedupe" "$MONITOR_99_AGAIN" "payload['rotation_candidates'] == []"

write_usage 99 "2026-05-25T12:00:00+00:00"
MONITOR_99_RESET="$(run_monitor)"
json_assert "usage 99 reset" "$MONITOR_99_RESET" "len(payload['rotation_candidates']) == 1"
pass "usage monitor emits one weekly rotation candidate per reset cycle"

# Weekly usage uses its own proactive threshold while 5h keeps the hard
# rotation threshold.

WEEKLY_ROTATION_STATE="$USAGE_ROOT/weekly-rotation-state.json"

run_monitor_proactive() {
  "$PYTHON" "$REPO_ROOT/bridge-usage.py" monitor \
    --claude-usage-cache "$USAGE_CACHE" \
    --codex-sessions-dir "$USAGE_CODEX" \
    --state-file "$WEEKLY_ROTATION_STATE" \
    --rotation-threshold 99 \
    --weekly-warn-threshold 95 \
    --json
}

# 94% - below weekly_warn_threshold; no rotation candidate.
write_usage 94 "2026-06-10T12:00:00+00:00"
MONITOR_WP_94="$(run_monitor_proactive)"
json_assert "weekly proactive 94" "$MONITOR_WP_94" "payload['rotation_candidates'] == []"

# 95% - at weekly threshold; normal rotation candidate fires.
write_usage 95 "2026-06-10T12:00:00+00:00"
MONITOR_WP_95="$(run_monitor_proactive)"
json_assert "weekly proactive 95 fires" "$MONITOR_WP_95" "len(payload['rotation_candidates']) == 1 and payload['rotation_candidates'][0]['window'] == 'weekly' and payload['rotation_candidates'][0]['rotation_threshold'] == 95.0 and payload['rotation_candidates'][0]['rotation_threshold_name'] == 'weekly_warn_threshold'"

# 95% again - latch dedupe; candidate should NOT re-fire.
MONITOR_WP_95_AGAIN="$(run_monitor_proactive)"
json_assert "weekly proactive 95 dedupe" "$MONITOR_WP_95_AGAIN" "payload['rotation_candidates'] == []"

# 99% in same reset cycle stays deduped because the 95% weekly candidate
# already fired for this reset.
write_usage 99 "2026-06-10T12:00:00+00:00"
MONITOR_WP_99="$(run_monitor_proactive)"
json_assert "weekly proactive 99 deduped after 95" "$MONITOR_WP_99" "payload['rotation_candidates'] == []"

# Reset cycle rollover - rotation latch clears and fires again.
write_usage 96 "2026-06-17T12:00:00+00:00"
MONITOR_WP_96_RESET="$(run_monitor_proactive)"
json_assert "weekly proactive rollover re-fires" "$MONITOR_WP_96_RESET" "len(payload['rotation_candidates']) == 1 and payload['rotation_candidates'][0]['window'] == 'weekly'"

# 5h remains tied to rotation_threshold; weekly threshold does not lower it.
FIVE_H_STATE="$USAGE_ROOT/five-hour-threshold-state.json"
write_usage 10 "2026-06-17T12:00:00+00:00" 98
MONITOR_5H_98="$(
  "$PYTHON" "$REPO_ROOT/bridge-usage.py" monitor \
    --claude-usage-cache "$USAGE_CACHE" \
    --codex-sessions-dir "$USAGE_CODEX" \
    --state-file "$FIVE_H_STATE" \
    --rotation-threshold 99 \
    --weekly-warn-threshold 95 \
    --json
)"
json_assert "5h still below 99" "$MONITOR_5H_98" "payload['rotation_candidates'] == []"
write_usage 10 "2026-06-17T12:00:00+00:00" 99
MONITOR_5H_99="$(
  "$PYTHON" "$REPO_ROOT/bridge-usage.py" monitor \
    --claude-usage-cache "$USAGE_CACHE" \
    --codex-sessions-dir "$USAGE_CODEX" \
    --state-file "$FIVE_H_STATE" \
    --rotation-threshold 99 \
    --weekly-warn-threshold 95 \
    --json
)"
json_assert "5h still triggers at 99" "$MONITOR_5H_99" "len(payload['rotation_candidates']) == 1 and payload['rotation_candidates'][0]['window'] == '5h' and payload['rotation_candidates'][0]['rotation_threshold_name'] == 'rotation_threshold'"
pass "weekly preemptive monitor: weekly fires at 95%, latches per cycle, and 5h still waits for 99%"

# bridge-usage.sh passes --weekly-warn-threshold from env var when no registry
# value is present.
SHELL_USAGE_STATE="$USAGE_ROOT/shell-state.json"
write_usage 96 "2026-06-01T12:00:00+00:00"
SHELL_MONITOR_WP="$(
  BRIDGE_CLAUDE_USAGE_CACHE="$USAGE_CACHE" \
  BRIDGE_CODEX_SESSIONS_DIR="$USAGE_CODEX" \
  BRIDGE_USAGE_MONITOR_STATE_FILE="$SHELL_USAGE_STATE" \
  BRIDGE_CLAUDE_TOKEN_REGISTRY="$USAGE_ROOT/no-registry.json" \
  BRIDGE_CLAUDE_WEEKLY_WARN_PERCENT=90 \
  "$REPO_ROOT/agent-bridge" usage monitor --json
)"
json_assert "usage shell weekly warn threshold env" "$SHELL_MONITOR_WP" "len(payload['rotation_candidates']) == 1 and payload['rotation_candidates'][0]['window'] == 'weekly' and payload['rotation_candidates'][0]['rotation_threshold'] == 90.0"
pass "bridge-usage.sh passes BRIDGE_CLAUDE_WEEKLY_WARN_PERCENT as --weekly-warn-threshold"

"$REPO_ROOT/agent-bridge" auth claude-token auto-rotate enable --threshold 98 --weekly-warn-threshold 93 --json >/dev/null
AUTO_ROTATE_STATUS="$("$REPO_ROOT/agent-bridge" auth claude-token auto-rotate status --json)"
json_assert "auto rotate status carries weekly threshold" "$AUTO_ROTATE_STATUS" "payload['rotation_threshold'] == 98.0 and payload['weekly_warn_threshold'] == 93.0"

REGISTRY_WEEKLY_STATE="$USAGE_ROOT/registry-weekly-state.json"
write_usage 94 "2026-06-08T12:00:00+00:00"
SHELL_MONITOR_REGISTRY_WEEKLY="$(
  BRIDGE_CLAUDE_USAGE_CACHE="$USAGE_CACHE" \
  BRIDGE_CODEX_SESSIONS_DIR="$USAGE_CODEX" \
  BRIDGE_USAGE_MONITOR_STATE_FILE="$REGISTRY_WEEKLY_STATE" \
  "$REPO_ROOT/agent-bridge" usage monitor --json
)"
json_assert "usage shell registry weekly warn threshold" "$SHELL_MONITOR_REGISTRY_WEEKLY" "len(payload['rotation_candidates']) == 1 and payload['rotation_candidates'][0]['window'] == 'weekly' and payload['rotation_candidates'][0]['rotation_threshold'] == 93.0"
pass "bridge-usage.sh reads registry weekly_warn_threshold"

write_usage 10 "2026-06-01T12:00:00+00:00" 98
SHELL_MONITOR="$(
  BRIDGE_CLAUDE_USAGE_CACHE="$USAGE_CACHE" \
  BRIDGE_CODEX_SESSIONS_DIR="$USAGE_CODEX" \
  BRIDGE_USAGE_MONITOR_STATE_FILE="$SHELL_USAGE_STATE" \
  "$REPO_ROOT/agent-bridge" usage monitor --json
)"
json_assert "usage shell registry threshold" "$SHELL_MONITOR" "len(payload['rotation_candidates']) == 1 and payload['rotation_candidates'][0]['window'] == '5h' and payload['rotation_candidates'][0]['rotation_threshold'] == 98.0"
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
    BRIDGE_ADMIN_AGENT_ID="admin" \
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
