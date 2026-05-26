#!/usr/bin/env bash
# scripts/smoke/6607-hook-admin-allowlist.sh — issue #6607 regression smoke.
#
# Pins the anchored admin bridge-verb allowlist that replaces the prior
# unconditional `if admin: return None` bypass at the end of
# `protected_alias_reason`. Codex r1 rejected the unconditional bypass
# as a broad command-injection surface; the prescription is an anchored
# allowlist of EXACT command shapes (no regex `.*`), audited via a
# distinct `tool_policy_admin_bridge_verb_allowed` row.
#
# Layer 1 (real PreToolUse hook end-to-end) — assertions:
#   - admin runs `agb auth claude-token add --stdin --activate`  → ALLOW + audit
#   - admin runs `agb a2a send --to peer --body-file /tmp/msg.txt`  → ALLOW + audit
#   - admin runs `agb escalate question "help"`  → ALLOW + audit
#   - non-admin `agb auth claude-token add ...`  → DENY (admin-only verb)
#   - admin `env > /tmp/leak`  → DENY (env-dump deny preserved ABOVE the
#                                       verb allowlist — the brief mandates
#                                       this stays denied even for admin)
#   - admin `agb a2a send --body-file ../../secret`  → DENY (path traversal
#                                                        rejected by safe-path
#                                                        validation)
#   - admin `agb auth claude-token add --exec /bin/sh`  → DENY (unknown flag
#                                                            cannot be smuggled
#                                                            through the verb
#                                                            shape)
#   - admin `agb auth claude-token add --token-file /tmp/safe.txt`  → ALLOW + audit
#   - admin `agb auth claude-token activate abc-123`  → ALLOW + audit
#   - admin `agb auth claude-token rotate --reason "auto"`  → ALLOW + audit
#
# Smoke layout mirrors scripts/smoke/admin-hook-exemption.sh and
# scripts/smoke/tool-policy-roster-read-classify.sh: printf-built JSON
# payload to a temp file, `< file` into the hook (NEVER an interpreter
# heredoc-stdin — footgun #11).

set -euo pipefail

SMOKE_NAME="6607-hook-admin-allowlist"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

# Two agents, one admin and one non-admin, via SESSION-TYPE.md (matches
# `_admin_agent_from_session_type` in hooks/tool-policy.py).
ADMIN_AGENT="patch-6607-admin"
USER_AGENT="ops-6607-user"
for AGENT in "$ADMIN_AGENT" "$USER_AGENT"; do
  HOME_DIR="$BRIDGE_AGENT_HOME_ROOT/$AGENT"
  mkdir -p "$HOME_DIR"
done
printf -- '- session type: admin\n' >"$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT/SESSION-TYPE.md"
printf -- '- session type: ops\n' >"$BRIDGE_AGENT_HOME_ROOT/$USER_AGENT/SESSION-TYPE.md"

# JSON-escape a Bash command string for embedding in the payload. Same
# helper shape as scripts/smoke/tool-policy-roster-read-classify.sh.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

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
    '  "tool_use_id": "smoke-6607",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

run_pretool_hook() {
  local agent="$1"
  local payload_file="$2"
  BRIDGE_AGENT_ID="$agent" \
    "$PYTHON_BIN" "$SMOKE_REPO_ROOT/hooks/tool-policy.py" <"$payload_file"
}

audit_log() {
  printf '%s\n' "${BRIDGE_AUDIT_LOG:-$BRIDGE_LOG_DIR/audit.jsonl}"
}

count_audit_rows() {
  # $1 action, $2 target (agent).
  local audit
  audit="$(audit_log)"
  if [[ ! -f "$audit" ]]; then
    printf '0\n'
    return 0
  fi
  grep "\"action\": \"$1\"" "$audit" 2>/dev/null \
    | grep -c "\"target\": \"$2\"" || true
}

# Run the hook and assert the verdict + (optional) audit-row delta.
# $1 label, $2 agent, $3 command, $4 verdict (ALLOW|DENY), $5 expected
# new audit rows ("" = don't check; "+1" = expect exactly one new row).
assert_hook_verdict() {
  local label="$1"
  local agent="$2"
  local command="$3"
  local want="$4"
  local audit_delta="${5:-}"
  local payload out got
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM.json"
  write_bash_payload "$payload" "$command"

  local before_count after_count
  before_count="$(count_audit_rows tool_policy_admin_bridge_verb_allowed "$agent")"

  out="$(run_pretool_hook "$agent" "$payload")"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then
    got="DENY"
  else
    got="ALLOW"
  fi
  if [[ "$got" != "$want" ]]; then
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      command: ${command}"
    smoke_log "      hook output: ${out:-<empty>}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi

  if [[ -n "$audit_delta" ]]; then
    after_count="$(count_audit_rows tool_policy_admin_bridge_verb_allowed "$agent")"
    case "$audit_delta" in
      "+1")
        if (( after_count != before_count + 1 )); then
          smoke_fail "${label}: expected +1 audit row, got delta $((after_count - before_count))"
        fi
        ;;
      "0")
        if (( after_count != before_count )); then
          smoke_fail "${label}: expected 0 audit-row delta, got $((after_count - before_count))"
        fi
        ;;
      *)
        smoke_fail "${label}: unknown audit_delta spec '$audit_delta'"
        ;;
    esac
  fi

  smoke_log "ok: ${label} -> ${got}"
}

smoke_log "layer 1 — real PreToolUse hook with anchored verb allowlist"

# --- Allowed verb shapes — admin --------------------------------------------

assert_hook_verdict \
  "admin: auth claude-token add --stdin --activate" \
  "$ADMIN_AGENT" \
  "agb auth claude-token add --stdin --activate" \
  "ALLOW" "+1"

assert_hook_verdict \
  "admin: auth claude-token add --token-file (safe absolute path)" \
  "$ADMIN_AGENT" \
  "agb auth claude-token add --token-file /tmp/safe-token.txt --activate" \
  "ALLOW" "+1"

assert_hook_verdict \
  "admin: auth claude-token activate <slug-id>" \
  "$ADMIN_AGENT" \
  "agb auth claude-token activate abc-123 --sync" \
  "ALLOW" "+1"

assert_hook_verdict \
  "admin: auth claude-token rotate --reason (free-text reason)" \
  "$ADMIN_AGENT" \
  "agb auth claude-token rotate --reason auto-rotate-ok --if-auto-enabled" \
  "ALLOW" "+1"

assert_hook_verdict \
  "admin: auth claude-token sync (no args)" \
  "$ADMIN_AGENT" \
  "agb auth claude-token sync" \
  "ALLOW" "+1"

assert_hook_verdict \
  "admin: escalate question (free-text body)" \
  "$ADMIN_AGENT" \
  "agb escalate question how-do-i-rotate-the-token" \
  "ALLOW" "+1"

assert_hook_verdict \
  "admin: a2a send --body-file (safe absolute path)" \
  "$ADMIN_AGENT" \
  "agb a2a send --to peer --body-file /tmp/msg.txt" \
  "ALLOW" "+1"

assert_hook_verdict \
  "admin: a2a send --body=inline (no body-file, inline body)" \
  "$ADMIN_AGENT" \
  "agb a2a send --to peer --body=inline-text" \
  "ALLOW" "+1"

assert_hook_verdict \
  "admin: full-path agent-bridge leaf + auth (path-prefix tolerated)" \
  "$ADMIN_AGENT" \
  "/usr/local/bin/agent-bridge auth claude-token sync" \
  "ALLOW" "+1"

# --- Denied: admin-only verbs running under non-admin -----------------------

assert_hook_verdict \
  "non-admin: auth claude-token add (admin-only verb)" \
  "$USER_AGENT" \
  "agb auth claude-token add --stdin --activate" \
  "DENY" "0"

assert_hook_verdict \
  "non-admin: auth claude-token rotate (admin-only verb)" \
  "$USER_AGENT" \
  "agb auth claude-token rotate" \
  "DENY" "0"

# Non-admin can still use the open verbs (`escalate question`, `a2a send`).
assert_hook_verdict \
  "non-admin: escalate question (open verb)" \
  "$USER_AGENT" \
  "agb escalate question please-rotate-my-token" \
  "ALLOW" "+1"

assert_hook_verdict \
  "non-admin: a2a send --body-file (safe path, open verb)" \
  "$USER_AGENT" \
  "agb a2a send --to peer --body-file /tmp/msg.txt" \
  "ALLOW" "+1"

# --- Denied: env-dump deny preserved ABOVE the allowlist --------------------

# The brief explicitly mandates: `env > /tmp/leak` STILL denied for admin.
# That deny is the credential/env gate at protected_alias_reason() line
# ~1817, which fires BEFORE the verb allowlist. Redirecting `env` output
# to a file drops the read-intent flag, so even admin gets denied.
assert_hook_verdict \
  "admin: env > /tmp/leak (env-dump deny survives admin path)" \
  "$ADMIN_AGENT" \
  "env > /tmp/leak.txt" \
  "DENY" "0"

# --- Denied: path traversal in a bridge-verb argument -----------------------

# Path validation rejects literal `..` components — the brief explicitly
# mandates this case denies despite matching the `a2a send` verb shape.
assert_hook_verdict \
  "admin: a2a send --body-file ../../secret (path traversal)" \
  "$ADMIN_AGENT" \
  "agb a2a send --to peer --body-file ../../secret" \
  "DENY" "0"

assert_hook_verdict \
  "admin: a2a send --body-file=../../secret (packed flag form, traversal)" \
  "$ADMIN_AGENT" \
  "agb a2a send --to peer --body-file=../../secret" \
  "DENY" "0"

# --- Denied: malformed --body-file shapes (codex r1 PR #1243) ---------------
#
# Codex r1 surfaced three malformed shapes that the prior `_extract_flag_value`
# collapsed into the "absent" branch and audited as ALLOW:
#   - `agb a2a send --body-file`                          (flag with no value)
#   - `agb a2a send --body-file --to peer`                (next token is another flag)
#   - `agb a2a send --body-file /tmp/ok --body-file ../../secret` (duplicate)
# The r2 fix splits absent vs malformed via two sentinels and emits a
# distinct `tool_policy_admin_bridge_verb_denied_shape` audit row for the
# malformed branch. These three counter-proofs pin all three repro shapes
# so a future refactor that silently re-collapses absent + malformed
# trips this smoke immediately.
assert_hook_shape_deny() {
  local label="$1"
  local agent="$2"
  local command="$3"
  local payload out got
  payload="$SMOKE_TMP_ROOT/payload-shape-$RANDOM.json"
  write_bash_payload "$payload" "$command"

  local allowed_before allowed_after denied_before denied_after
  allowed_before="$(count_audit_rows tool_policy_admin_bridge_verb_allowed "$agent")"
  denied_before="$(count_audit_rows tool_policy_admin_bridge_verb_denied_shape "$agent")"

  out="$(run_pretool_hook "$agent" "$payload")"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then
    got="DENY"
  else
    got="ALLOW"
  fi
  if [[ "$got" != "DENY" ]]; then
    smoke_log "FAIL: ${label} -> ${got}, want DENY"
    smoke_log "      command: ${command}"
    smoke_log "      hook output: ${out:-<empty>}"
    smoke_fail "${label}: expected DENY, got ${got}"
  fi

  allowed_after="$(count_audit_rows tool_policy_admin_bridge_verb_allowed "$agent")"
  denied_after="$(count_audit_rows tool_policy_admin_bridge_verb_denied_shape "$agent")"

  if (( allowed_after != allowed_before )); then
    smoke_fail "${label}: must NOT emit _allowed audit row (got delta $((allowed_after - allowed_before)))"
  fi
  if (( denied_after != denied_before + 1 )); then
    smoke_fail "${label}: expected +1 _denied_shape audit row, got delta $((denied_after - denied_before))"
  fi
  smoke_log "ok: ${label} -> DENY + _denied_shape audit row"
}

assert_hook_shape_deny \
  "admin: a2a send --body-file (no value — codex r1 case 1)" \
  "$ADMIN_AGENT" \
  "agb a2a send --body-file"

assert_hook_shape_deny \
  "admin: a2a send --body-file --to peer (next token is flag — codex r1 case 2)" \
  "$ADMIN_AGENT" \
  "agb a2a send --body-file --to peer"

assert_hook_shape_deny \
  "admin: a2a send --body-file /tmp/ok --body-file ../../secret (duplicate — codex r1 case 3)" \
  "$ADMIN_AGENT" \
  "agb a2a send --body-file /tmp/ok --body-file ../../secret"

# --- Denied: unknown flag smuggle attempts ---------------------------------

# An unknown flag like `--exec` MUST be rejected — the allowlist is
# anchored to the documented `bridge-auth.sh` flag surface so a future
# extension flag (e.g. one that takes a path to a shell script) cannot
# silently inherit the bypass.
assert_hook_verdict \
  "admin: auth claude-token add --exec /bin/sh (unknown flag)" \
  "$ADMIN_AGENT" \
  "agb auth claude-token add --exec /bin/sh" \
  "DENY" "0"

assert_hook_verdict \
  "admin: auth claude-token add positional arg (no positional permitted)" \
  "$ADMIN_AGENT" \
  "agb auth claude-token add some-positional-token-value" \
  "DENY" "0"

# --- Structural defense: shell-embedding / multi-command must NOT trip
#     the allowlist's audit emission (allow/deny still depends on the
#     rest of the gate chain; we assert that the allowlist itself
#     refused to bless these commands).

# A `$()` embedding inside the verb argv must fail the structural gate
# (mirrors `_is_config_set_wrapper` — codex r2 #726 prescription). The
# command falls through to the rest of the gate chain; the safety
# property we pin here is "the allowlist did NOT emit an audit row" —
# i.e. the carve-out refused to fire, so a future protected-path check
# (if any) still has the opportunity to deny. With no protected path in
# `cat /tmp/x` the chain ends in allow, but the verb allowlist is not
# implicated.
shell_embed_payload="$SMOKE_TMP_ROOT/payload-shell-embed.json"
write_bash_payload "$shell_embed_payload" \
  "agb auth claude-token add --token-file \$(cat /tmp/x)"
before_embed_count="$(count_audit_rows tool_policy_admin_bridge_verb_allowed "$ADMIN_AGENT")"
shell_embed_out="$(run_pretool_hook "$ADMIN_AGENT" "$shell_embed_payload")"
after_embed_count="$(count_audit_rows tool_policy_admin_bridge_verb_allowed "$ADMIN_AGENT")"
if (( after_embed_count != before_embed_count )); then
  smoke_fail "shell-embedding case: allowlist must NOT emit audit row (got delta $((after_embed_count - before_embed_count)))"
fi
# Result is whatever the surrounding gates decide; the contract is that
# the allowlist did not bless the command.
smoke_log "ok: shell-embedding \$() did not trip the verb allowlist (audit delta = 0)"

# A `;` separator must also drop the allowlist carve-out so a trailing
# command cannot ride the audit row through.
multi_cmd_payload="$SMOKE_TMP_ROOT/payload-multi-cmd.json"
write_bash_payload "$multi_cmd_payload" \
  "agb auth claude-token add --stdin ; echo trailing"
before_multi_count="$(count_audit_rows tool_policy_admin_bridge_verb_allowed "$ADMIN_AGENT")"
run_pretool_hook "$ADMIN_AGENT" "$multi_cmd_payload" >/dev/null
after_multi_count="$(count_audit_rows tool_policy_admin_bridge_verb_allowed "$ADMIN_AGENT")"
if (( after_multi_count != before_multi_count )); then
  smoke_fail "multi-command ';' case: allowlist must NOT emit audit row (got delta $((after_multi_count - before_multi_count)))"
fi
smoke_log "ok: multi-command ';' separator did not trip the verb allowlist (audit delta = 0)"

# --- Sanity: non-bridge commands still pass when nothing protected ---------

# A benign admin command that doesn't reference a bridge verb should
# still pass through the rest of the gate chain. This is the regression
# guard for: "removing the broad `if admin: return None` bypass must
# not break unrelated admin commands."
assert_hook_verdict \
  "admin: benign ls /tmp (no bridge verb, falls through)" \
  "$ADMIN_AGENT" \
  "ls /tmp" \
  "ALLOW" "0"

# --- Audit ledger sanity ----------------------------------------------------

# The allow path MUST emit the new audit action so operators can grep
# for admin verb bypasses.
audit_count="$(count_audit_rows tool_policy_admin_bridge_verb_allowed "$ADMIN_AGENT")"
if (( audit_count == 0 )); then
  smoke_fail "expected at least one tool_policy_admin_bridge_verb_allowed audit row for $ADMIN_AGENT, got 0"
fi
smoke_log "audit: $audit_count tool_policy_admin_bridge_verb_allowed rows for $ADMIN_AGENT"

smoke_log "passed"
