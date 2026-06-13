#!/usr/bin/env bash
# scripts/smoke/1879-agent-set-model-hook-spoof.sh — issue #1879 (PR #1887 r2).
#
# Closes the BLOCKING trust-boundary bypass agb-dev-codex found on PR #1887: the
# new `agent set-model` / `agent set-effort` verbs write BRIDGE_AGENT_MODEL /
# BRIDGE_AGENT_EFFORT into the #341-protected agent-roster.local.sh through the
# audited materialize-fields writer, and that writer trusts an explicit
# `BRIDGE_CALLER_SOURCE=operator-tui` env override. That is safe ONLY if the
# PreToolUse hook denies an AGENT-AUTHORED env-prefix spoof of that very
# caller-source. The wrapper sibling smoke (1879-agent-set-model-effort.sh) drives
# the WRITER trust gate; THIS smoke drives the real hook hooks/tool-policy.py and
# proves the env-prefix-spoof anti-spoof gate (mirroring the `config set-env`
# anti-spoof gate, v0166-lc-config-set-env.sh §3/§4).
#
# Two surfaces:
#   (deny) a non-admin agent context running the forged-prefix set-model/set-effort
#          in EVERY spelling config set-env covers (bare VAR=, env(1), env -S,
#          grouping, separators, quote-concat, direct bridge-agent.sh, embeddings,
#          redirects) -> hook DENY, same reason class as config set-env, no write.
#   (allow) a legitimate operator/admin shape with NO agent-authored spoof prefix
#          -> hook ALLOW (the wrapper's own #341 caller-source gate then decides).
#
# Footgun #11 / lint-heredoc-ban: ALL JSON payloads are built with printf and
# `>` file-redirect; the hook reads the payload from a file with `< file`. No
# heredoc / here-string operator appears anywhere (including comments).
#
# macOS: pure policy-decision smoke; no sudo / multi-UID. Runs under
# /opt/homebrew/bin/bash 5.x and Linux CI bash alike.

set -euo pipefail

SMOKE_NAME="1879-agent-set-model-hook-spoof"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
HOOK="$REPO_ROOT/hooks/tool-policy.py"
export BRIDGE_ADMIN_AGENT_ID="patch"

# --- Fixtures ---------------------------------------------------------------

# Admin agent: SESSION-TYPE.md == admin makes is_admin_agent() true in the hook.
ADMIN_AGENT="patch"
ADMIN_HOME="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
mkdir -p "$ADMIN_HOME"
printf -- '- session type: admin\n' >"$ADMIN_HOME/SESSION-TYPE.md"

# Non-admin agent — its forged-prefix attempts must STAY denied.
USER_AGENT="worker"
USER_HOME="$BRIDGE_AGENT_HOME_ROOT/$USER_AGENT"
mkdir -p "$USER_HOME"
printf -- '- session type: static\n' >"$USER_HOME/SESSION-TYPE.md"

# Seed the roster with a sentinel so a regression that lets a spoofed write
# through (and clobbers the roster) is caught — denied attempts must not mutate.
ROSTER_SENTINEL='BRIDGE_AGENT_DESCRIPTION_patch="1879-spoof-sentinel"'
printf '%s\n' "$ROSTER_SENTINEL" >"$BRIDGE_ROSTER_LOCAL_FILE"

roster_sha() {
  "$PYTHON_BIN" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$BRIDGE_ROSTER_LOCAL_FILE"
}
ROSTER_SHA_BEFORE="$(roster_sha)"

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
    '  "tool_use_id": "smoke-1879",' \
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

echo "[smoke:${SMOKE_NAME}] agent set-model/set-effort hook anti-spoof gate"

# ===========================================================================
# SECTION 1 — DENY: agent-authored caller-source env-prefix spoof, every spelling.
# Each of these forges BRIDGE_CALLER_SOURCE=operator-tui (or BRIDGE_AGENT_ID) in
# front of the roster-writing wrapper. ALL must DENY at the hook (same class the
# config set-env gate denies), regardless of caller role.
# ===========================================================================

# 1a. bare VAR=value prefix (the confirmed PR-head bypass).
assert_bash_verdict \
  "deny: bare VAR= prefix set-model (non-admin)" \
  "$USER_AGENT" \
  "BRIDGE_CALLER_SOURCE=operator-tui agent-bridge agent set-model victim claude-opus-4-8" \
  "DENY"
assert_bash_verdict \
  "deny: bare VAR= prefix set-effort (non-admin)" \
  "$USER_AGENT" \
  "BRIDGE_CALLER_SOURCE=operator-tui agb agent set-effort victim xhigh" \
  "DENY"

# 1b. BRIDGE_AGENT_ID spoof (non-admin tries to become admin) + the override.
assert_bash_verdict \
  "deny: AGENT_ID spoof prefix" \
  "$USER_AGENT" \
  "BRIDGE_AGENT_ID=patch BRIDGE_CALLER_SOURCE=operator-tui agb agent set-model victim claude-opus-4-8" \
  "DENY"

# 1c. env(1) / /usr/bin/env utility prefix.
assert_bash_verdict \
  "deny: env(1) prefix spoof" \
  "$USER_AGENT" \
  "env BRIDGE_CALLER_SOURCE=operator-tui agb agent set-model victim claude-opus-4-8" \
  "DENY"
assert_bash_verdict \
  "deny: /usr/bin/env prefix spoof" \
  "$USER_AGENT" \
  "/usr/bin/env BRIDGE_CALLER_SOURCE=operator-tui agent-bridge agent set-effort victim high" \
  "DENY"

# 1d. env -i / env -- option-bearing prefix.
assert_bash_verdict \
  "deny: env -i prefix spoof" \
  "$USER_AGENT" \
  "env -i BRIDGE_AGENT_ID=patch BRIDGE_CALLER_SOURCE=operator-tui agb agent set-model victim claude-opus-4-8" \
  "DENY"
assert_bash_verdict \
  "deny: env -- prefix spoof" \
  "$USER_AGENT" \
  "env -- BRIDGE_CALLER_SOURCE=operator-tui agb agent set-effort victim low" \
  "DENY"

# 1e. env -S / --split-string packed payload (hides the verb in one token).
assert_bash_verdict \
  "deny: env -S packed payload spoof" \
  "$USER_AGENT" \
  "env -S 'BRIDGE_CALLER_SOURCE=operator-tui agent-bridge' agent set-model victim claude-opus-4-8" \
  "DENY"
assert_bash_verdict \
  "deny: env --split-string= payload spoof" \
  "$USER_AGENT" \
  "env --split-string='BRIDGE_AGENT_ID=patch agent-bridge' agent set-effort victim xhigh" \
  "DENY"

# 1f. shell reserved word / grouping metacharacter prefixes.
assert_bash_verdict \
  "deny: time keyword prefix spoof" \
  "$USER_AGENT" \
  "time BRIDGE_CALLER_SOURCE=operator-tui agb agent set-model victim m" \
  "DENY"
assert_bash_verdict \
  "deny: subshell ( ) prefix spoof" \
  "$USER_AGENT" \
  "(BRIDGE_CALLER_SOURCE=operator-tui agb agent set-model victim claude-opus-4-8)" \
  "DENY"
assert_bash_verdict \
  "deny: no-space subshell (agb spoof" \
  "$USER_AGENT" \
  "(BRIDGE_CALLER_SOURCE=operator-tui agb agent set-effort victim high)" \
  "DENY"

# 1g. multi-stage separator spoof: seed the trust env in a preceding stage.
assert_bash_verdict \
  "deny: preceding export; stage spoof" \
  "$USER_AGENT" \
  "export BRIDGE_CALLER_SOURCE=operator-tui; agb agent set-model victim claude-opus-4-8" \
  "DENY"
assert_bash_verdict \
  "deny: preceding export && stage spoof" \
  "$USER_AGENT" \
  "export BRIDGE_AGENT_ID=patch && agb agent set-effort victim xhigh" \
  "DENY"

# 1h. quote-concat / backslash-escape of the verb token.
assert_bash_verdict \
  "deny: quote-concat set\"-\"model spoof" \
  "$USER_AGENT" \
  'BRIDGE_CALLER_SOURCE=operator-tui agb agent set"-"model victim claude-opus-4-8' \
  "DENY"
assert_bash_verdict \
  "deny: backslash-escape set\\-effort spoof" \
  "$USER_AGENT" \
  'BRIDGE_CALLER_SOURCE=operator-tui agb agent set\-effort victim high' \
  "DENY"

# 1i. direct bridge-agent.sh script spelling (no protected-path argv backstop).
assert_bash_verdict \
  "deny: direct bridge-agent.sh set-model spoof" \
  "$USER_AGENT" \
  "BRIDGE_CALLER_SOURCE=operator-tui bash bridge-agent.sh set-model victim claude-opus-4-8" \
  "DENY"
assert_bash_verdict \
  "deny: direct bridge-agent.sh set-effort spoof" \
  "$USER_AGENT" \
  "BRIDGE_AGENT_ID=patch BRIDGE_CALLER_SOURCE=operator-tui bash bridge-agent.sh set-effort victim xhigh" \
  "DENY"

# 1j. shell embedding / redirect / separator smuggle on a recognized attempt.
assert_bash_verdict \
  "deny: cmd-subst smuggle" \
  "$USER_AGENT" \
  'agb agent set-model victim $(whoami)' \
  "DENY"
assert_bash_verdict \
  "deny: redirect smuggle" \
  "$USER_AGENT" \
  "agb agent set-model victim m > /tmp/1879-leak" \
  "DENY"
assert_bash_verdict \
  "deny: trailing separator smuggle" \
  "$USER_AGENT" \
  "agb agent set-model victim m; cat /etc/passwd" \
  "DENY"
assert_bash_verdict \
  "deny: pipe smuggle" \
  "$USER_AGENT" \
  "agb agent set-effort victim high | tee /tmp/1879-leak" \
  "DENY"

# 1k. an admin forging the prefix is ALSO denied — the env-prefix spoof is
#     denied irrespective of role (the prefix forges the trust env the wrapper
#     reads; an admin has no need to forge it).
assert_bash_verdict \
  "deny: admin forged prefix still denied" \
  "$ADMIN_AGENT" \
  "BRIDGE_CALLER_SOURCE=operator-tui agb agent set-model victim claude-opus-4-8" \
  "DENY"

# Confirm NOTHING was written by any denied attempt (roster byte-identical).
smoke_assert_eq "$ROSTER_SHA_BEFORE" "$(roster_sha)" "deny: roster bytes untouched after all spoof denies"
smoke_assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "$ROSTER_SENTINEL" \
  "deny: roster sentinel preserved"

# ===========================================================================
# SECTION 2 — ALLOW: legitimate operator/admin shape (no agent-authored spoof
# prefix). The hook lets the clean shape through; the WRAPPER's own #341
# caller-source gate then decides (the wrapper smoke covers that). Don't
# over-block the legitimate operator path.
# ===========================================================================

# 2a. clean canonical wrapper shapes (both front-ends, both verbs).
assert_bash_verdict \
  "allow: clean agb agent set-model" \
  "$USER_AGENT" \
  "agb agent set-model victim claude-opus-4-8" \
  "ALLOW"
assert_bash_verdict \
  "allow: clean agent-bridge agent set-effort" \
  "$USER_AGENT" \
  "agent-bridge agent set-effort victim xhigh" \
  "ALLOW"

# 2b. clean direct bridge-agent.sh interpreter shape (the wrapper invokes it
#     this way: `bash bridge-agent.sh set-model …`).
assert_bash_verdict \
  "allow: clean bash bridge-agent.sh set-model" \
  "$USER_AGENT" \
  "bash bridge-agent.sh set-model victim claude-opus-4-8" \
  "ALLOW"

# 2c. safe stderr-discard suffix must not break the carve-out.
assert_bash_verdict \
  "allow: clean set-model 2>/dev/null" \
  "$USER_AGENT" \
  "agb agent set-model victim claude-opus-4-8 2>/dev/null" \
  "ALLOW"

# 2d. flags after the value (--dry-run / --json) stay allowed.
assert_bash_verdict \
  "allow: clean set-model --dry-run" \
  "$ADMIN_AGENT" \
  "agb agent set-model victim claude-opus-4-8 --dry-run" \
  "ALLOW"

# 2e. an UNRELATED `agent` verb must NOT be hijacked by the gate.
assert_bash_verdict \
  "allow: unrelated agb agent list not hijacked" \
  "$USER_AGENT" \
  "agb agent list" \
  "ALLOW"

# 2f. an UNRELATED `VAR=value cmd` (not a set-model/effort verb) is not hijacked.
assert_bash_verdict \
  "allow: unrelated VAR=value cmd not hijacked" \
  "$USER_AGENT" \
  "FOO=bar echo hello" \
  "ALLOW"

# Roster still byte-identical after the ALLOW probes (the hook does not write;
# only the wrapper would, and these probes never invoke it).
smoke_assert_eq "$ROSTER_SHA_BEFORE" "$(roster_sha)" "allow: roster bytes still untouched"

smoke_log "PASS: agent set-model/set-effort hook anti-spoof gate held (deny spoofs, allow clean)"
