#!/usr/bin/env bash
# scripts/smoke/v0166-lc-config-set-env.sh — Issue #1734 (v0.16.6 Lane C).
#
# `agb config set-env KEY=VALUE` gives the admin a durable, audited install
# env-override path (the roster is blocked by #341; `config set` is JSON-only).
# This is a SECURITY-SENSITIVE surface — it touches the #341 write-gate — so
# the smoke is negative-control-FIRST: every spoof / forbidden-key / smuggle
# shape MUST be denied, and only the narrow sanctioned shape applies.
#
# Two real surfaces are driven end-to-end:
#   (A) the wrapper bridge-config.py — caller-trust gate + key allowlist /
#       deny-list + per-key value typing + atomic shell-safe write +
#       before/after-hash audit row.
#   (B) the real PreToolUse hook hooks/tool-policy.py — the exact-shape,
#       admin-only, anti-spoof Bash gate for `config set-env` AND the #341
#       PROTECTED_GLOBS direct-Edit/Write deny for agent-env.local.sh.
#
# MANDATORY negative controls (brief):
#   - non-admin caller            -> denied (wrapper + hook)
#   - env-assignment spoof         -> denied (hook)
#     (BRIDGE_CALLER_SOURCE=… / BRIDGE_AGENT_ID=… agb config set-env …)
#   - forbidden key (BRIDGE_HOME / *TOKEN* / BRIDGE_A2A_ALLOW_TEST_BIND)
#                                  -> denied (wrapper)
#   - shell-embedding in the value -> denied (wrapper + hook)
# Positives:
#   - allowed key by admin/operator-TTY -> applied to agent-env.local.sh as a
#     quoted export; roster/role bytes untouched; audit row w/ before+after hash
#   - agent-env.local.sh in PROTECTED_GLOBS -> direct Edit/Write still blocked
#
# Footgun #11 / lint-heredoc-ban: ALL fixtures + JSON payloads are built with
# printf and `>` file-redirect — never an interpreter here-string / heredoc-
# stdin. The hook payload is piped from a file with `< file`. No heredoc /
# here-string operator appears anywhere in this script, including comments.
#
# macOS: pure policy-decision + file-write smoke; no sudo / multi-UID needed.
# Runs under /opt/homebrew/bin/bash 5.x and Linux CI bash alike.

set -euo pipefail

SMOKE_NAME="v0166-lc-config-set-env"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
WRAPPER="$REPO_ROOT/bridge-config.py"
HOOK="$REPO_ROOT/hooks/tool-policy.py"
ENV_FILE="$BRIDGE_HOME/agent-env.local.sh"
export BRIDGE_AGENT_ENV_LOCAL_FILE="$ENV_FILE"
export BRIDGE_ADMIN_AGENT_ID="patch"

# --- Fixtures ---------------------------------------------------------------

# Admin agent: SESSION-TYPE.md == admin makes is_admin_agent() true in the
# hook; the wrapper keys on BRIDGE_ADMIN_AGENT_ID + the caller's agent id.
ADMIN_AGENT="patch"
ADMIN_HOME="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
mkdir -p "$ADMIN_HOME"
printf -- '- session type: admin\n' >"$ADMIN_HOME/SESSION-TYPE.md"

# Non-admin agent — its set-env attempts must STAY denied.
USER_AGENT="worker"
USER_HOME="$BRIDGE_AGENT_HOME_ROOT/$USER_AGENT"
mkdir -p "$USER_HOME"
printf -- '- session type: static\n' >"$USER_HOME/SESSION-TYPE.md"

# Seed the roster with a sentinel "role" line so a regression that clobbers
# the roster instead of writing the dedicated file is caught.
ROSTER_SENTINEL='BRIDGE_AGENT_DESCRIPTION_patch="lane-c-sentinel"'
printf '%s\n' "$ROSTER_SENTINEL" >"$BRIDGE_ROSTER_LOCAL_FILE"

roster_sha() {
  "$PYTHON_BIN" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$BRIDGE_ROSTER_LOCAL_FILE"
}
ROSTER_SHA_BEFORE="$(roster_sha)"

# Issue #1738: the wrapper now authorizes from a controller-published pane
# binding matched against its own process ancestry, NOT from env identity. The
# wrapper subprocess is a descendant of THIS smoke shell ($$), so a binding
# whose pane_pid == $$ matches its ancestry — that is how we drive the positive
# admin path here (in production the controller publishes pane_pid after
# `tmux new-session`). Negative controls publish NO binding (or a non-admin
# one), so the env-trust spoof shapes stay denied.
BINDINGS_DIR="$BRIDGE_STATE_DIR/config-caller-bindings"
mkdir -p "$BINDINGS_DIR"
seed_admin_binding() {
  printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"s","pane_pid":%s,"engine":"claude","updated_at":"now"}\n' \
    "$ADMIN_AGENT" "$ADMIN_AGENT" "$$" >"$BINDINGS_DIR/$ADMIN_AGENT.json"
}
clear_bindings() {
  rm -f "$BINDINGS_DIR"/*.json 2>/dev/null || true
}

# --- Wrapper plumbing -------------------------------------------------------

# Run the wrapper with a chosen caller agent + source. Echoes rc on a trailing
# line; stdout/stderr captured by the caller via command substitution.
# $1 agent, $2 caller_source, $3.. set-env argv.
run_wrapper() {
  local agent="$1" source="$2"
  shift 2
  set +e
  BRIDGE_AGENT_ID="$agent" \
  BRIDGE_CALLER_SOURCE="$source" \
    "$PYTHON_BIN" "$WRAPPER" set-env "$@" >"$SMOKE_TMP_ROOT/wrap.out" 2>"$SMOKE_TMP_ROOT/wrap.err"
  local rc=$?
  set -e
  printf '%s' "$rc"
}

assert_wrapper_denied() {
  local label="$1" agent="$2" source="$3" arg="$4"
  local rc
  rc="$(run_wrapper "$agent" "$source" "$arg")"
  if [[ "$rc" == "0" ]]; then
    smoke_log "FAIL: ${label}: wrapper rc=0 (expected non-zero deny)"
    smoke_log "      out: $(cat "$SMOKE_TMP_ROOT/wrap.out")"
    smoke_fail "${label}: expected deny, got apply"
  fi
  smoke_assert_contains "$(cat "$SMOKE_TMP_ROOT/wrap.err")" "deny" "${label}: deny message"
  smoke_log "ok: ${label} -> deny (rc=${rc})"
}

# --- Hook plumbing (printf only) --------------------------------------------

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

write_bash_payload() {
  local target="$1" command="$2" esc
  esc="$(json_escape "$command")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1734",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

write_file_payload() {
  local target="$1" tool="$2" file_path="$3" esc
  esc="$(json_escape "$file_path")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    "  \"tool_name\": \"${tool}\"," \
    "  \"tool_input\": {\"file_path\": \"${esc}\", \"content\": \"export X=1\"}," \
    '  "tool_use_id": "smoke-1734",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

# $1 agent, $2 payload-file -> echoes ALLOW|DENY
hook_verdict_file() {
  local agent="$1" payload="$2" out
  out="$(BRIDGE_AGENT_ID="$agent" "$PYTHON_BIN" "$HOOK" <"$payload")"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then
    printf 'DENY'
  else
    printf 'ALLOW'
  fi
}

assert_bash_verdict() {
  local label="$1" agent="$2" command="$3" want="$4"
  local payload="$SMOKE_TMP_ROOT/p-$RANDOM-$RANDOM.json" got
  write_bash_payload "$payload" "$command"
  got="$(hook_verdict_file "$agent" "$payload")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      agent=${agent} command=${command}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

assert_file_verdict() {
  local label="$1" agent="$2" tool="$3" file_path="$4" want="$5"
  local payload="$SMOKE_TMP_ROOT/p-$RANDOM-$RANDOM.json" got
  write_file_payload "$payload" "$tool" "$file_path"
  got="$(hook_verdict_file "$agent" "$payload")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

echo "[smoke:${SMOKE_NAME}] config set-env wrapper + hook end-to-end"

# ===========================================================================
# SECTION 1 — WRAPPER negative controls (deny FIRST).
# ===========================================================================

# 1a. non-admin caller (even from operator-TTY source) -> denied.
assert_wrapper_denied \
  "wrapper: non-admin caller denied" \
  "$USER_AGENT" "operator-tui" \
  "BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400"

# 1b. admin but non-operator source (agent-direct) -> denied.
assert_wrapper_denied \
  "wrapper: admin + agent-direct source denied" \
  "$ADMIN_AGENT" "agent-direct" \
  "BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400"

# 1c. forbidden key: a root/identity var (BRIDGE_HOME) -> denied.
assert_wrapper_denied \
  "wrapper: forbidden key BRIDGE_HOME denied" \
  "$ADMIN_AGENT" "operator-tui" \
  "BRIDGE_HOME=/tmp/evil"

# 1d. forbidden key: a *TOKEN* secret-bearing name -> denied.
assert_wrapper_denied \
  "wrapper: forbidden *TOKEN* key denied" \
  "$ADMIN_AGENT" "operator-tui" \
  "BRIDGE_A2A_SHARED_TOKEN=x"

# 1e. forbidden key: the test-bypass bind flag -> denied.
assert_wrapper_denied \
  "wrapper: ALLOW_TEST_BIND denied" \
  "$ADMIN_AGENT" "operator-tui" \
  "BRIDGE_A2A_ALLOW_TEST_BIND=1"

# 1f. forbidden key: a path/executable override lever -> denied.
assert_wrapper_denied \
  "wrapper: WARP_CLI exec lever denied" \
  "$ADMIN_AGENT" "operator-tui" \
  "BRIDGE_A2A_WARP_CLI=/tmp/evil"

# 1g. non-allowlist key (well-formed but not exposed) -> denied.
assert_wrapper_denied \
  "wrapper: non-allowlist key denied" \
  "$ADMIN_AGENT" "operator-tui" \
  "BRIDGE_A2A_RANDOM_KNOB=5"

# 1h. shell-embedding in the value -> denied (type screen rejects non-int).
assert_wrapper_denied \
  "wrapper: shell-embed in value denied" \
  "$ADMIN_AGENT" "operator-tui" \
  "BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400; rm -rf /"

# 1i. out-of-range value (threshold below floor) -> denied.
assert_wrapper_denied \
  "wrapper: below-floor threshold denied" \
  "$ADMIN_AGENT" "operator-tui" \
  "BRIDGE_A2A_PEER_SUSPECT_THRESHOLD=1"

# Confirm NOTHING was written by any denied attempt.
if [[ -f "$ENV_FILE" ]]; then
  smoke_fail "managed env file exists after only-denied attempts: $ENV_FILE"
fi
smoke_log "ok: no managed file created by any denied attempt"

# ===========================================================================
# SECTION 2 — WRAPPER positive: allowed key by admin pane-binding applies.
# ===========================================================================

# Issue #1738: publish a matching admin pane binding so the wrapper's ancestry
# check authorizes the admin path (env identity alone no longer does).
seed_admin_binding

: >"$BRIDGE_AUDIT_LOG"
rc="$(run_wrapper "$ADMIN_AGENT" "operator-tui" "BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400")"
smoke_assert_eq "0" "$rc" "wrapper: allowed apply rc"
smoke_assert_file_exists "$ENV_FILE" "wrapper: managed file written"

# The value lands as a quoted shell export, single line, no eval.
ENV_BODY="$(cat "$ENV_FILE")"
smoke_assert_contains "$ENV_BODY" \
  "export BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS='86400'" \
  "wrapper: quoted export line"

# The managed file sources cleanly and yields the value.
SOURCED="$(/usr/bin/env bash -c "source '$ENV_FILE'; printf '%s' \"\${BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS:-UNSET}\"")"
smoke_assert_eq "86400" "$SOURCED" "wrapper: managed file sources to value"

# Roster / role bytes untouched.
ROSTER_SHA_AFTER="$(roster_sha)"
smoke_assert_eq "$ROSTER_SHA_BEFORE" "$ROSTER_SHA_AFTER" "wrapper: roster bytes untouched"
smoke_assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "$ROSTER_SENTINEL" \
  "wrapper: roster sentinel preserved"

# Audit row carries before + after hashes for the apply.
AUDIT="$(cat "$BRIDGE_AUDIT_LOG")"
smoke_assert_contains "$AUDIT" '"trigger": "set-env-apply"' "wrapper: apply audit row"
smoke_assert_contains "$AUDIT" '"before_sha256"' "wrapper: audit before hash"
smoke_assert_contains "$AUDIT" '"after_sha256"' "wrapper: audit after hash"
smoke_log "ok: wrapper applied allowed key with before/after-hash audit"

# A second allowed set-env replaces idempotently and preserves a sibling.
rc="$(run_wrapper "$ADMIN_AGENT" "operator-tui" "BRIDGE_A2A_RECONCILE_INTERVAL=60")"
smoke_assert_eq "0" "$rc" "wrapper: sibling apply rc"
rc="$(run_wrapper "$ADMIN_AGENT" "operator-tui" "BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=120")"
smoke_assert_eq "0" "$rc" "wrapper: replace apply rc"
EXPORT_COUNT="$(grep -c '^export ' "$ENV_FILE")"
smoke_assert_eq "2" "$EXPORT_COUNT" "wrapper: idempotent replace (no dup), sibling preserved"
smoke_log "ok: wrapper idempotent replace + sibling preserved"

# Audit row for a wrapper deny carries before hash but NO after hash.
: >"$BRIDGE_AUDIT_LOG"
run_wrapper "$ADMIN_AGENT" "operator-tui" "BRIDGE_HOME=/x" >/dev/null
DENY_AUDIT="$(cat "$BRIDGE_AUDIT_LOG")"
smoke_assert_contains "$DENY_AUDIT" '"trigger": "set-env-deny"' "wrapper: deny audit row"
smoke_assert_not_contains "$DENY_AUDIT" '"after_sha256"' "wrapper: deny row has NO after hash"
smoke_log "ok: wrapper deny audit row omits after hash"

# ===========================================================================
# SECTION 3 — HOOK negative controls (the Bash gate).
# ===========================================================================

# 3a. non-admin Bash `config set-env` -> denied.
assert_bash_verdict \
  "hook: non-admin set-env denied" \
  "$USER_AGENT" \
  "agb config set-env BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400" \
  "DENY"

# 3b. env-assignment spoof of BRIDGE_CALLER_SOURCE (admin session) -> denied.
assert_bash_verdict \
  "hook: env-assign spoof CALLER_SOURCE denied" \
  "$ADMIN_AGENT" \
  "BRIDGE_CALLER_SOURCE=operator-tui agb config set-env BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400" \
  "DENY"

# 3c. env-assignment spoof of BRIDGE_AGENT_ID (non-admin tries to become admin)
#     -> denied.
assert_bash_verdict \
  "hook: env-assign spoof AGENT_ID denied" \
  "$USER_AGENT" \
  "BRIDGE_AGENT_ID=patch agb config set-env BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400" \
  "DENY"

# 3e. env(1)-utility prefix spoof — `env VAR=v agb config set-env` seeds the
#     wrapper's trust env exactly like a bare VAR= prefix. Pre-fix this bypassed
#     first-stage-only recognition (#11710 P1 / patch write-gate #11711). DENY.
assert_bash_verdict \
  "hook: env(1) prefix spoof denied" \
  "$USER_AGENT" \
  "env BRIDGE_AGENT_ID=patch BRIDGE_CALLER_SOURCE=operator-tui agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"
assert_bash_verdict \
  "hook: /usr/bin/env prefix spoof denied" \
  "$USER_AGENT" \
  "/usr/bin/env BRIDGE_AGENT_ID=patch agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"

# 3f. preceding-stage `export VAR=v;` then set-env — a separate stage seeds the
#     trust env; recognition must catch set-env in a LATER stage (#11710/#11711).
assert_bash_verdict \
  "hook: preceding export; stage spoof denied" \
  "$USER_AGENT" \
  "export BRIDGE_AGENT_ID=patch; agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"

# 3g. `export VAR=v &&` then set-env — same multi-stage spoof via &&. DENY.
assert_bash_verdict \
  "hook: preceding export && stage spoof denied" \
  "$USER_AGENT" \
  "export BRIDGE_CALLER_SOURCE=operator-tui && agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"

# 3h. option-bearing env wrappers (`env -i` / `env --` / `/usr/bin/env -i`) —
#     the env-options weren't consumed by the r2 enumerator (codex r2 #11717).
#     The canonical-shape gate denies them uniformly (token[0] != agb verb).
assert_bash_verdict \
  "hook: env -i prefix spoof denied" \
  "$USER_AGENT" \
  "env -i BRIDGE_ADMIN_AGENT_ID=patch BRIDGE_AGENT_ID=patch BRIDGE_CALLER_SOURCE=operator-tui agb config set-env BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400" \
  "DENY"
assert_bash_verdict \
  "hook: env -- prefix spoof denied" \
  "$USER_AGENT" \
  "env -- BRIDGE_AGENT_ID=patch agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"

# 3i. shell reserved words / grouping metacharacters (`time`, `!`, subshell
#     `(…)`, group `{…}`) also apply a leading env-assignment but are not PATH
#     binaries (patch write-gate r2 #11718). The canonical-shape gate denies
#     them without enumerating each one.
assert_bash_verdict \
  "hook: time keyword prefix spoof denied" \
  "$USER_AGENT" \
  "time BRIDGE_AGENT_ID=patch agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"
assert_bash_verdict \
  "hook: ! keyword prefix spoof denied" \
  "$USER_AGENT" \
  "! BRIDGE_AGENT_ID=patch agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"
assert_bash_verdict \
  "hook: subshell ( ) prefix spoof denied" \
  "$USER_AGENT" \
  "(BRIDGE_AGENT_ID=patch agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60)" \
  "DENY"
assert_bash_verdict \
  "hook: group { } prefix spoof denied" \
  "$USER_AGENT" \
  "{ BRIDGE_AGENT_ID=patch agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60; }" \
  "DENY"
assert_bash_verdict \
  "hook: time env -i combo spoof denied" \
  "$USER_AGENT" \
  "time env -i BRIDGE_AGENT_ID=patch agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"

# 3j. `env -S` / `--split-string` payload packing (codex r3 #11726). GNU env -S
#     re-parses its single STRING arg into assignments + the command word at
#     runtime, hiding the verb triple inside one shell token. The recognizer
#     expands the payload so the triple resurfaces; canonical-shape gate denies.
assert_bash_verdict \
  "hook: env -S packed payload spoof denied" \
  "$USER_AGENT" \
  "env -S 'BRIDGE_AGENT_ID=patch BRIDGE_CALLER_SOURCE=operator-tui agent-bridge' config set-env BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400" \
  "DENY"
assert_bash_verdict \
  "hook: env -S whole-command payload denied" \
  "$USER_AGENT" \
  "env -S 'agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60'" \
  "DENY"
assert_bash_verdict \
  "hook: env --split-string= payload spoof denied" \
  "$USER_AGENT" \
  "env --split-string='BRIDGE_AGENT_ID=patch agent-bridge' config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"
assert_bash_verdict \
  "hook: env -iS bundled-flag payload denied" \
  "$USER_AGENT" \
  "env -iS 'BRIDGE_AGENT_ID=patch agb' config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"

# 3k. direct-script wrapper spelling (codex r3 #11726). `set-env` has NO
#     protected-path argv backstop, so `python3 bridge-config.py set-env …`
#     (with spoofed trust env) would bypass the hook entirely if only the
#     `agb config set-env` spelling were recognized. Recognize the direct
#     `bridge-config.py set-env` spelling too; canonical-shape gate denies it.
assert_bash_verdict \
  "hook: direct python3 bridge-config.py set-env (spoof env) denied" \
  "$USER_AGENT" \
  "BRIDGE_ADMIN_AGENT_ID=patch BRIDGE_AGENT_ID=patch BRIDGE_CALLER_SOURCE=operator-tui python3 bridge-config.py set-env BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400" \
  "DENY"
assert_bash_verdict \
  "hook: direct bridge-config.py set-env (bare) denied" \
  "$USER_AGENT" \
  "python3 bridge-config.py set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "DENY"

# 3l. subshell with NO space after `(` (bash needs none: `(agb …)` is a valid
#     subshell). shlex glues `(agb` into one token; the recognizer neutralizes
#     grouping parens so the inner verb surfaces. Canonical-shape gate denies.
assert_bash_verdict \
  "hook: no-space subshell (agb spoof denied" \
  "$USER_AGENT" \
  "(BRIDGE_AGENT_ID=patch agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60)" \
  "DENY"

# 3m. bash quote-concatenation / backslash-escape of the `set-env` token
#     (codex r5 #11733). `set"-"env`, `set-en''v`, `set\-env` all shlex-resolve
#     to the exact `set-env` token, but evade a raw-substring prefilter. The
#     prefilter now strips shell quote/escape chars before the substring check;
#     the verb still surfaces in the shlex scan -> canonical-shape gate denies.
assert_bash_verdict \
  "hook: set quote-concat wrapper spoof denied" \
  "$USER_AGENT" \
  'BRIDGE_AGENT_ID=patch BRIDGE_CALLER_SOURCE=operator-tui agb config set"-"env BRIDGE_A2A_RECONCILE_INTERVAL=60' \
  "DENY"
assert_bash_verdict \
  "hook: set quote-concat direct-script spoof denied" \
  "$USER_AGENT" \
  'BRIDGE_ADMIN_AGENT_ID=patch BRIDGE_AGENT_ID=patch python3 bridge-config.py set"-"env BRIDGE_A2A_RECONCILE_INTERVAL=60' \
  "DENY"
assert_bash_verdict \
  "hook: set quote-concat inside env -S payload denied" \
  "$USER_AGENT" \
  "env -S 'BRIDGE_AGENT_ID=patch agb config set\"-\"env BRIDGE_A2A_RECONCILE_INTERVAL=60'" \
  "DENY"
assert_bash_verdict \
  "hook: set backslash-escape spoof denied" \
  "$USER_AGENT" \
  'BRIDGE_AGENT_ID=patch agb config set\-env BRIDGE_A2A_RECONCILE_INTERVAL=60' \
  "DENY"

# 3n. bash line-continuation of the `set-env` token (codex r6 #11742). bash
#     removes `\<newline>` (and `\<CR><newline>`) before tokenizing, so
#     `set-\<NL>env` runs as the `set-env` token, yet shlex does NOT collapse
#     it. Built with $'…' ANSI-C quoting so the literal backslash-newline
#     survives THIS script's own parsing. The recognizer joins line
#     continuations at entry; the canonical-shape gate denies.
LC_WRAP=$'BRIDGE_AGENT_ID=patch BRIDGE_CALLER_SOURCE=operator-tui agb config set-\\\nenv BRIDGE_A2A_RECONCILE_INTERVAL=60'
assert_bash_verdict \
  "hook: line-continuation wrapper spoof denied" \
  "$USER_AGENT" "$LC_WRAP" "DENY"
LC_DIRECT=$'BRIDGE_ADMIN_AGENT_ID=patch BRIDGE_AGENT_ID=patch python3 bridge-config.py set-\\\nenv BRIDGE_A2A_RECONCILE_INTERVAL=60'
assert_bash_verdict \
  "hook: line-continuation direct-script spoof denied" \
  "$USER_AGENT" "$LC_DIRECT" "DENY"
LC_ENVS=$'env -S \'BRIDGE_AGENT_ID=patch agb config set-\\\nenv BRIDGE_A2A_RECONCILE_INTERVAL=60\''
assert_bash_verdict \
  "hook: line-continuation inside env -S denied" \
  "$USER_AGENT" "$LC_ENVS" "DENY"

# 3d. shell-embedding / separator smuggles on a recognized set-env attempt.
assert_bash_verdict \
  "hook: separator smuggle denied" \
  "$ADMIN_AGENT" \
  "agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60; cat /etc/passwd" \
  "DENY"
assert_bash_verdict \
  "hook: redirect smuggle denied" \
  "$ADMIN_AGENT" \
  "agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60 > /tmp/leak" \
  "DENY"
assert_bash_verdict \
  "hook: cmd-subst smuggle denied" \
  "$ADMIN_AGENT" \
  'agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=$(whoami)' \
  "DENY"
assert_bash_verdict \
  "hook: pipe smuggle denied" \
  "$ADMIN_AGENT" \
  "agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60 | tee /tmp/leak" \
  "DENY"

# ===========================================================================
# SECTION 4 — HOOK positives + #341 PROTECTED_GLOBS teeth.
# ===========================================================================

# 4a. sanctioned admin `config set-env` (both front-ends) -> allowed.
assert_bash_verdict \
  "hook: admin set-env (agb) allowed" \
  "$ADMIN_AGENT" \
  "agb config set-env BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400" \
  "ALLOW"
assert_bash_verdict \
  "hook: admin set-env (agent-bridge) allowed" \
  "$ADMIN_AGENT" \
  "agent-bridge config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" \
  "ALLOW"
# Safe stderr-discard suffix must not break the carve-out.
assert_bash_verdict \
  "hook: admin set-env 2>/dev/null allowed" \
  "$ADMIN_AGENT" \
  "agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60 2>/dev/null" \
  "ALLOW"

# 4b. an UNRELATED `VAR=value cmd` (not set-env) must NOT be hijacked -> allowed.
assert_bash_verdict \
  "hook: unrelated VAR=value cmd not hijacked" \
  "$ADMIN_AGENT" \
  "FOO=bar echo hello" \
  "ALLOW"

# 4c. existing `config set` (JSON) carve-out still works -> allowed.
assert_bash_verdict \
  "hook: config set (json) carve-out intact" \
  "$ADMIN_AGENT" \
  "agb config set --path /tmp/x.json --change a=b" \
  "ALLOW"

# 4d. agent-env.local.sh is in PROTECTED_GLOBS: direct Edit/Write blocked (#341).
assert_file_verdict \
  "hook: Write agent-env.local.sh blocked (#341)" \
  "$ADMIN_AGENT" "Write" "$ENV_FILE" "DENY"
assert_file_verdict \
  "hook: Edit agent-env.local.sh blocked (#341)" \
  "$ADMIN_AGENT" "Edit" "$ENV_FILE" "DENY"

# 4e. read-intent of the managed file stays ALLOWED (protected-path read carve-out).
assert_bash_verdict \
  "hook: read-intent cat agent-env.local.sh allowed" \
  "$ADMIN_AGENT" \
  "cat $ENV_FILE" \
  "ALLOW"

smoke_log "PASS: all config set-env wrapper + hook + #341 cases held"
