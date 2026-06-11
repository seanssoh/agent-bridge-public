#!/usr/bin/env bash
# scripts/smoke/1358-admin-credential-routine-exempt.sh — regression
# for issue #1358 (Track F, v0.15.0-beta5-2).
#
# Tactical carve-out: admin agent's `bash bridge-auth.sh claude-token
# add --stdin …` is allowed past the `_raw_mentions_claude_credentials`
# substring deny so rotation pool registration succeeds when the
# operator pipes a fresh OAuth token via stdin. Defense-in-depth
# preserved: strict prefix match + admin role gate + audit emit on
# every exemption.
#
# T1–T6 cover the brief's smoke matrix plus the security teeth:
#
#   T1  admin + sanctioned shape           -> allow + audit emit
#   T2  admin + raw `cat .credentials.json` -> deny (other rules still bite)
#   T3  non-admin + sanctioned shape       -> deny (admin-only gate)
#   T4  admin + sanctioned shape && chain  -> deny (strict prefix match)
#   T5  admin + missing --stdin            -> deny (strict argv shape)
#   T6  admin + sanctioned shape carries
#       a `sk-ant-o…` substring (operator
#       piped via `echo …|`)               -> allow + audit emit
#
# Footgun #11 discipline: JSON stdin payload built with `printf` (never
# an interpreter heredoc-stdin) and piped into the hook with `< file`.
# Mirrors scripts/smoke/admin-hook-exemption.sh.

set -euo pipefail

SMOKE_NAME="1358-admin-credential-routine-exempt"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

# --- Layer 1: helper unit assertions ---------------------------------------

echo "[smoke:${SMOKE_NAME}] layer 1 — _is_admin_credential_routine unit"
"$PYTHON_BIN" "$SCRIPT_DIR/1358-admin-credential-routine-exempt.py"

# --- Layer 2: real PreToolUse hook end-to-end ------------------------------

# JSON-escape a Bash command string for embedding in the PreToolUse
# payload. Escapes `\`, `"`, and a literal newline.
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
    "  \"tool_use_id\": \"smoke-1358-$RANDOM\"," \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

# PreToolUse payload for a non-Bash Grep tool (used by T16 to exercise
# the non-Bash credential-deny summary token-value redaction).
write_grep_payload() {
  local target="$1"
  local pattern="$2"
  local esc
  esc="$(json_escape "$pattern")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Grep",' \
    "  \"tool_input\": {\"pattern\": \"${esc}\"}," \
    "  \"tool_use_id\": \"smoke-1358-$RANDOM\"," \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

# PreToolUse payload for a Write tool (file_path + content). Used by T17
# to exercise the INDEPENDENT `system_config_mutation` audit row's
# non-Bash `operation` token-value redaction (#1358 r4).
write_write_payload() {
  local target="$1"
  local file_path="$2"
  local content="$3"
  local esc_path esc_content
  esc_path="$(json_escape "$file_path")"
  esc_content="$(json_escape "$content")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Write",' \
    "  \"tool_input\": {\"file_path\": \"${esc_path}\", \"content\": \"${esc_content}\"}," \
    "  \"tool_use_id\": \"smoke-1358-$RANDOM\"," \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

run_pretool_hook() {
  # Codex r1 BLOCKING #2 (2026-05-29): the credential carve-out's
  # admin check is strict-agreement — env BRIDGE_ADMIN_AGENT_ID AND
  # SESSION-TYPE.md must both confirm admin. The bash smoke default
  # passes BRIDGE_ADMIN_AGENT_ID matching the agent id; T11 callers
  # override the env explicitly to exercise the disagreement case.
  local agent="$1"
  local payload_file="$2"
  local admin_id="${3:-${BRIDGE_ADMIN_AGENT_ID:-$agent}}"
  BRIDGE_AGENT_ID="$agent" \
    BRIDGE_ADMIN_AGENT_ID="$admin_id" \
    "$PYTHON_BIN" "$SMOKE_REPO_ROOT/hooks/tool-policy.py" <"$payload_file"
}

setup_agent_home() {
  local agent="$1"
  local kind="$2"  # admin | user
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$home"
  if [[ "$kind" == "admin" ]]; then
    printf -- '- session type: admin\n' >"$home/SESSION-TYPE.md"
  else
    printf -- '- session type: ops\n' >"$home/SESSION-TYPE.md"
  fi
}

audit_log_path() {
  printf '%s\n' "${BRIDGE_AUDIT_LOG:-$BRIDGE_LOG_DIR/audit.jsonl}"
}

# Count audit rows with both the action and the target agent set.
count_audit_rows() {
  local agent="$1"
  local action="$2"
  local audit
  audit="$(audit_log_path)"
  if [[ ! -f "$audit" ]]; then
    printf '0\n'
    return 0
  fi
  grep "\"action\": \"$action\"" "$audit" 2>/dev/null \
    | grep -c "\"target\": \"$agent\"" || true
}

assert_hook_verdict() {
  # Optional 5th arg: override BRIDGE_ADMIN_AGENT_ID for the env-roster
  # disagreement test cases (T11). Default is the agent id itself so the
  # strict-agreement gate is satisfied when SESSION-TYPE.md=admin.
  local label="$1"
  local agent="$2"
  local command="$3"
  local want="$4"  # ALLOW | DENY
  local admin_id="${5:-$agent}"
  local payload out got
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM.json"
  write_bash_payload "$payload" "$command"
  out="$(run_pretool_hook "$agent" "$payload" "$admin_id")"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then
    got="DENY"
  else
    got="ALLOW"
  fi
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      command: ${command}"
    smoke_log "      hook output: ${out:-<empty>}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

assert_audit_row_added() {
  local label="$1"
  local agent="$2"
  local action="$3"
  local before="$4"
  local after
  after="$(count_audit_rows "$agent" "$action")"
  if (( after > before )); then
    smoke_log "ok: ${label} audit row appended (before=${before} after=${after})"
  else
    smoke_fail "${label}: expected new ${action} audit row (before=${before} after=${after})"
  fi
}

# --- Driver ---------------------------------------------------------------

main() {
  smoke_require_cmd "$PYTHON_BIN"
  smoke_setup_bridge_home "$SMOKE_NAME"

  setup_agent_home admin-1358 admin
  setup_agent_home user-1358 user

  local action="tool_policy_credential_routine_admin_exempted"

  # T1 — sanctioned shape from admin -> allow + audit emit.
  local before_t1
  before_t1="$(count_audit_rows admin-1358 "$action")"
  assert_hook_verdict \
    "T1 admin + sanctioned shape" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id pool-a --enable-auto-rotate" \
    "ALLOW"
  assert_audit_row_added \
    "T1 audit emit" admin-1358 "$action" "$before_t1"

  # T2 — admin + raw credentials path read (NOT the sanctioned shape).
  # The credential-mention rule fires; admin's read-intent carve-out
  # already covers `cat ~/.claude/.credentials.json` (existing
  # `agent_admin_credential_read_allowed` row), but a non-existent
  # path with a write-intent shape still denies. Use a path that
  # contains both `.claude` and `.credentials.json` AND an output
  # redirect so the read-intent flag drops and the deny holds — that
  # is the gate the brief calls "other rules still bite".
  assert_hook_verdict \
    "T2 admin + raw credentials write" \
    admin-1358 \
    "cat /tmp/.claude/.credentials.json > /tmp/leak.json" \
    "DENY"

  # T3 — non-admin + sanctioned shape WITH a credential substring ->
  # deny (admin-only carve-out; substring rule still bites the
  # non-admin). Without a substring the shape itself isn't protected
  # — only the credential gates around it — so we anchor the deny on
  # the substring rule for the non-admin path.
  assert_hook_verdict \
    "T3 non-admin + sanctioned shape with sk-ant-o substring" \
    user-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id pool-sk-ant-o-fake" \
    "DENY"

  # T4 — admin + sanctioned shape WITH a trailing chain -> deny (the
  # `&&` separator must drop the carve-out so a chained command cannot
  # ride past the credential mention). Use a chain whose second
  # command itself contains a credential substring so the deny is
  # provably triggered by the substring rule (not by something else).
  assert_hook_verdict \
    "T4 admin + sanctioned shape && chain" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin && echo sk-ant-o-stealth >&2" \
    "DENY"

  # T5 — admin + missing `--stdin` -> deny (strict argv shape requires
  # `--stdin`; without it the token would arrive as a positional /
  # value-flag value, a different leakage shape not unblocked here).
  # Include the credential substring so we know the deny is triggered
  # by the substring rule once the carve-out shape mismatches.
  assert_hook_verdict \
    "T5 admin + missing --stdin" \
    admin-1358 \
    "echo sk-ant-o-fake | bash bridge-auth.sh claude-token add --id pool-a" \
    "DENY"

  # T6 — admin + sanctioned shape with operator piping the token
  # substring via `echo …|` -> allow + audit emit. This is the actual
  # OOTB case from the issue: the OAuth token substring is in the
  # command text, but the destination is the sanctioned strict prefix.
  local before_t6
  before_t6="$(count_audit_rows admin-1358 "$action")"
  assert_hook_verdict \
    "T6 admin + sanctioned shape with sk-ant-o substring" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id pool-sk-ant-o-fake --enable-auto-rotate" \
    "ALLOW"
  assert_audit_row_added \
    "T6 audit emit" admin-1358 "$action" "$before_t6"

  # T6 teeth — the audit row's sample / summary must NOT carry the
  # raw token. Codex r1 BLOCKING #1 (2026-05-29): without redaction,
  # the sanctioned shape's here-string body / argv slug carrying
  # `sk-ant-o…` lands in the audit log verbatim. Verify:
  #   (a) the exemption discriminator is present (so consumers can
  #       grep this row);
  #   (b) neither the here-string body substring nor the bare
  #       `sk-ant-o…` slug payload appears in any audit row.
  local audit
  audit="$(audit_log_path)"
  if grep -q '"exemption": "credential_routine_admin"' "$audit"; then
    smoke_log "ok: T6 audit carries exemption discriminator"
  else
    smoke_fail "T6 audit: missing exemption discriminator field"
  fi

  # T7 — Codex r1 BLOCKING #1 (r2, 2026-05-29) — hash-only audit row.
  # Schema now carries `command_sha256` (64-char lowercase hex of the
  # original command bytes) and NO command text in any form. Invoke
  # the sanctioned shape with a here-string body and verify:
  #   (a) no canary substring survives anywhere in the audit log;
  #   (b) the row carries a 64-char hex `command_sha256` field;
  #   (c) no `sample` / `summary` / `command` / `description` field is
  #       present in the row.
  local before_t7
  before_t7="$(count_audit_rows admin-1358 "$action")"
  local token='sk-ant-o-leak-canary-9b3a1d'
  assert_hook_verdict \
    "T7 hash-only audit — here-string body" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< '${token}'" \
    "ALLOW"
  assert_audit_row_added \
    "T7 audit emit" admin-1358 "$action" "$before_t7"
  if grep -q "leak-canary-9b3a1d" "$audit"; then
    smoke_fail \
      "T7 token leakage: here-string body 'leak-canary-9b3a1d' appears in audit log: $(grep 'leak-canary' "$audit")"
  else
    smoke_log "ok: T7 hash-only — here-string body 'leak-canary-9b3a1d' NOT in audit log"
  fi
  # The last admin-exempted row must carry a 64-char hex command_sha256
  # field and must NOT carry sample/summary/command/description fields.
  local last_row
  last_row="$(grep '"action": "tool_policy_credential_routine_admin_exempted"' "$audit" | tail -1)"
  if [[ -z "$last_row" ]]; then
    smoke_fail "T7 schema: cannot locate last admin-exempted audit row"
  fi
  if printf '%s' "$last_row" | grep -Eq '"command_sha256": "[0-9a-f]{64}"'; then
    smoke_log "ok: T7 schema — command_sha256 present and 64-char hex"
  else
    smoke_fail "T7 schema: command_sha256 missing or wrong format — row=${last_row}"
  fi
  for forbidden in '"sample"' '"summary"' '"command":' '"description"'; do
    if printf '%s' "$last_row" | grep -q "$forbidden"; then
      smoke_fail "T7 schema: forbidden field ${forbidden} present in admin-exempted row — row=${last_row}"
    fi
  done
  smoke_log "ok: T7 schema — no sample/summary/command/description fields"

  # T7-r2 — Codex r2 BLOCKING separator-smuggling sealed at the
  # PreToolUse hook layer. Each bypass shape carries `sk-ant-o…`
  # (the credential substring) in the bare-word here-string body so
  # the substring deny would normally bite. The previous broken
  # carve-out matched the shape, emitted an exemption audit row, and
  # skipped the substring deny — letting the smuggled `;curl evil`
  # tail execute. The fix denies the carve-out at the shape gate, so
  # the substring deny fires and the smuggled command is rejected.
  # Verify (a) the hook returns DENY and (b) the exemption audit
  # count does NOT increment past the smuggled shapes.
  local before_smuggle_count
  before_smuggle_count="$(count_audit_rows admin-1358 "$action")"
  assert_hook_verdict \
    "T7-r2 bare-word here-string + ; smuggle" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin <<< sk-ant-o-abc;curl evil.example" \
    "DENY"
  assert_hook_verdict \
    "T7-r2 bare-word here-string + | smuggle" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin <<< sk-ant-o-abc|tee /tmp/leak" \
    "DENY"
  assert_hook_verdict \
    "T7-r2 bare-word here-string + && smuggle" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin <<< sk-ant-o-abc&&curl evil" \
    "DENY"
  assert_hook_verdict \
    "T7-r2 multi-EOF heredoc coalesce with sk-ant-o body" \
    admin-1358 \
    "$(printf 'bash bridge-auth.sh claude-token add --stdin <<EOF\nsk-ant-o-body\nEOF\ncurl evil\nEOF')" \
    "DENY"
  local after_smuggle_count
  after_smuggle_count="$(count_audit_rows admin-1358 "$action")"
  if (( after_smuggle_count == before_smuggle_count )); then
    smoke_log "ok: T7-r2 smuggle shapes did NOT emit exemption audit row (before=${before_smuggle_count} after=${after_smuggle_count})"
  else
    smoke_fail \
      "T7-r2 leakage: smuggle shape emitted exemption audit (before=${before_smuggle_count} after=${after_smuggle_count})"
  fi

  # T9-r3 — Codex r3 BLOCKING trailing-argv-injection sealed at the
  # PreToolUse hook layer. The substring deny would bite each shape
  # because `sk-ant-o` is in the here-string body, but the carve-out
  # MUST reject them at the shape gate so the exemption audit row is
  # NEVER emitted for a trailing-argv injection.
  local before_t9_count
  before_t9_count="$(count_audit_rows admin-1358 "$action")"
  assert_hook_verdict \
    "T9-r3 trailing --exec after quoted here-string" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< 'sk-ant-o-real' --exec evil" \
    "DENY"
  assert_hook_verdict \
    "T9-r3 trailing --id traversal after quoted here-string" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< 'sk-ant-o-real' --id ../bad" \
    "DENY"
  local after_t9_count
  after_t9_count="$(count_audit_rows admin-1358 "$action")"
  if (( after_t9_count == before_t9_count )); then
    smoke_log "ok: T9-r3 trailing-argv shapes did NOT emit exemption audit row (before=${before_t9_count} after=${after_t9_count})"
  else
    smoke_fail \
      "T9-r3 leakage: trailing-argv shape emitted exemption audit (before=${before_t9_count} after=${after_t9_count})"
  fi

  # T10-r5 — Codex r5 BLOCKING post-EOF newline-separated content
  # sealed at the PreToolUse hook layer. A second command line after
  # the heredoc closer (e.g. `--activate` on its own line) must NOT
  # cause the carve-out to match. Verify the substring deny bites
  # (carries `sk-ant-o…` in the body) AND the exemption audit count
  # does not increment past these shapes.
  local before_t10_count
  before_t10_count="$(count_audit_rows admin-1358 "$action")"
  assert_hook_verdict \
    "T10-r5 post-EOF --activate on new line" \
    admin-1358 \
    "$(printf 'bash bridge-auth.sh claude-token add --stdin <<EOF\nsk-ant-o-real\nEOF\n--activate')" \
    "DENY"
  assert_hook_verdict \
    "T10-r5 post-EOF --enable-auto-rotate on new line" \
    admin-1358 \
    "$(printf 'bash bridge-auth.sh claude-token add --stdin <<EOF\nsk-ant-o-real\nEOF\n--enable-auto-rotate')" \
    "DENY"
  local after_t10_count
  after_t10_count="$(count_audit_rows admin-1358 "$action")"
  if (( after_t10_count == before_t10_count )); then
    smoke_log "ok: T10-r5 post-EOF shapes did NOT emit exemption audit row (before=${before_t10_count} after=${after_t10_count})"
  else
    smoke_fail \
      "T10-r5 leakage: post-EOF shape emitted exemption audit (before=${before_t10_count} after=${after_t10_count})"
  fi

  # T8 — Codex r1 BLOCKING #1 (r2): argv slug carrying the credential
  # prefix (operator-id-style smuggling) must NOT survive in the
  # hash-only audit row either. Same hash-only schema check as T7.
  local before_t8
  before_t8="$(count_audit_rows admin-1358 "$action")"
  local prefix_token='sk-ant-o-argv-canary-7e2c4f'
  assert_hook_verdict \
    "T8 hash-only audit — sk-ant-o argv slug" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id ${prefix_token}" \
    "ALLOW"
  assert_audit_row_added \
    "T8 audit emit" admin-1358 "$action" "$before_t8"
  if grep -q "argv-canary-7e2c4f" "$audit"; then
    smoke_fail \
      "T8 token leakage: sk-ant-o argv slug 'argv-canary-7e2c4f' appears in audit log: $(grep 'argv-canary' "$audit")"
  else
    smoke_log "ok: T8 hash-only — argv 'argv-canary-7e2c4f' NOT in audit log"
  fi
  # Also confirm raw 'sk-ant-o' does not appear in the last
  # admin-exempted row (the canary should be the only sk-ant-o source).
  local last_t8_row
  last_t8_row="$(grep '"action": "tool_policy_credential_routine_admin_exempted"' "$audit" | tail -1)"
  if printf '%s' "$last_t8_row" | grep -q 'sk-ant-o'; then
    smoke_fail "T8 schema: 'sk-ant-o' substring leaked into admin-exempted row — row=${last_t8_row}"
  fi
  if printf '%s' "$last_t8_row" | grep -Eq '"command_sha256": "[0-9a-f]{64}"'; then
    smoke_log "ok: T8 schema — command_sha256 present and 64-char hex"
  else
    smoke_fail "T8 schema: command_sha256 missing or wrong format — row=${last_t8_row}"
  fi

  # T11 — Codex r1 BLOCKING #2 (2026-05-29) — env-roster strict-
  # agreement gate. BRIDGE_ADMIN_AGENT_ID=admin-1358 but SESSION-TYPE.md
  # for admin-1358 is downgraded to ops. The carve-out MUST deny so the
  # substring rule fires; the audit count for admin-1358 must NOT
  # increment past this shape.
  local before_t11
  before_t11="$(count_audit_rows admin-1358 "$action")"
  printf -- '- session type: ops\n' >"$BRIDGE_AGENT_HOME_ROOT/admin-1358/SESSION-TYPE.md"
  assert_hook_verdict \
    "T11 env=admin-1358 + SESSION-TYPE.md=ops (env-spoof)" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< 'sk-ant-o-canary-t11'" \
    "DENY" \
    "admin-1358"
  local after_t11
  after_t11="$(count_audit_rows admin-1358 "$action")"
  if (( after_t11 == before_t11 )); then
    smoke_log "ok: T11 env-spoof did NOT emit exemption audit row (before=${before_t11} after=${after_t11})"
  else
    smoke_fail \
      "T11 leakage: env-spoof shape emitted exemption audit (before=${before_t11} after=${after_t11})"
  fi
  # T11c — Codex r2 BLOCKING (r3, 2026-05-29) sealed: the env-roster
  # MISMATCH deny path itself leaked the token. The carve-out denies
  # (T11 above), but the generic `agent_tool_denied` row's summary
  # scrub was gated on the role+shape predicate
  # (`_is_admin_credential_routine`) which returns False on env-roster
  # mismatch — so the scrub did NOT fire and the raw
  # `<<< 'sk-ant-o-canary-t11'` body landed in `detail.summary.command`.
  # The fix swaps that gate for the shape-only
  # `_should_hash_credential_routine_audit`, so the deny row is hashed
  # whenever the token-bearing shape is present regardless of the role
  # gate. Verify:
  #   (a) the T11 token canary does NOT appear ANYWHERE in the audit log;
  #   (b) the deny row's `detail.summary` is the hash-only form
  #       (`command_sha256` 64-char hex, no raw `command` / `description`).
  if grep -q "sk-ant-o-canary-t11" "$audit"; then
    smoke_fail \
      "T11c token leakage: env-roster-mismatch deny row leaked 'sk-ant-o-canary-t11' into audit log: $(grep 'sk-ant-o-canary-t11' "$audit")"
  else
    smoke_log "ok: T11c hash-only deny — 'sk-ant-o-canary-t11' NOT in audit log on env-roster mismatch"
  fi
  local last_t11_deny_row
  last_t11_deny_row="$(grep '"action": "agent_tool_denied"' "$audit" | grep '"target": "admin-1358"' | tail -1)"
  if [[ -z "$last_t11_deny_row" ]]; then
    smoke_fail "T11c: cannot locate last agent_tool_denied row for admin-1358"
  fi
  if printf '%s' "$last_t11_deny_row" | grep -Eq '"command_sha256": "[0-9a-f]{64}"'; then
    smoke_log "ok: T11c deny summary — command_sha256 present and 64-char hex"
  else
    smoke_fail "T11c deny summary: command_sha256 missing or wrong format — row=${last_t11_deny_row}"
  fi
  if printf '%s' "$last_t11_deny_row" | grep -q '"command":'; then
    smoke_fail "T11c deny summary: raw 'command' field present in env-roster-mismatch deny row — row=${last_t11_deny_row}"
  else
    smoke_log "ok: T11c deny summary — no raw 'command' field in agent_tool_denied row"
  fi
  if printf '%s' "$last_t11_deny_row" | grep -q '"description":'; then
    smoke_fail "T11c deny summary: raw 'description' field present in env-roster-mismatch deny row — row=${last_t11_deny_row}"
  else
    smoke_log "ok: T11c deny summary — no raw 'description' field in agent_tool_denied row"
  fi
  # T11b — env unset (or pointing elsewhere) + SESSION-TYPE.md=admin
  # for the agent: roster alone is not enough. Restore admin
  # SESSION-TYPE.md for admin-1358 and point env at a different id.
  printf -- '- session type: admin\n' >"$BRIDGE_AGENT_HOME_ROOT/admin-1358/SESSION-TYPE.md"
  local before_t11b
  before_t11b="$(count_audit_rows admin-1358 "$action")"
  assert_hook_verdict \
    "T11b env=other-id + SESSION-TYPE.md=admin (roster alone)" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< 'sk-ant-o-canary-t11b'" \
    "DENY" \
    "some-other-admin"
  local after_t11b
  after_t11b="$(count_audit_rows admin-1358 "$action")"
  if (( after_t11b == before_t11b )); then
    smoke_log "ok: T11b roster-alone did NOT emit exemption audit row (before=${before_t11b} after=${after_t11b})"
  else
    smoke_fail \
      "T11b leakage: roster-alone shape emitted exemption audit (before=${before_t11b} after=${after_t11b})"
  fi

  # T12 — env-roster agreement: BRIDGE_ADMIN_AGENT_ID=admin-1358 AND
  # SESSION-TYPE.md=admin -> ALLOW + audit emit. This is the canonical
  # admin rotation path; ensures the strict-agreement gate did not
  # over-deny the legitimate flow.
  local before_t12
  before_t12="$(count_audit_rows admin-1358 "$action")"
  assert_hook_verdict \
    "T12 env=admin-1358 + SESSION-TYPE.md=admin (both agree)" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --id pool-a" \
    "ALLOW" \
    "admin-1358"
  assert_audit_row_added \
    "T12 audit emit" admin-1358 "$action" "$before_t12"

  # T13 — Codex r1 BLOCKING #1 r3 (2026-05-29) sealed: sanctioned
  # carve-out shape that ALSO carries a credential-path argv flag
  # (`--token-file ~/.claude/.credentials.json`). The shape gate
  # accepts it (allowed flag + safe path), so the exemption row is
  # emitted (hash-only). The downstream credential-path argv gate
  # then DENIES the command. Before this fix, the `agent_tool_denied`
  # row carried the raw command via `detail.summary.command`, leaking
  # the heredoc-body OAuth token into the audit log even though the
  # exemption row above was hash-only. Verify:
  #   (a) the hook returns DENY;
  #   (b) the exemption row IS still emitted (the carve-out shape was
  #       recognised);
  #   (c) NO canary substring (the token body / argv slug) appears in
  #       ANY audit row — not just the exemption row;
  #   (d) the deny row's `detail.summary` is the hash-only form
  #       (`command_sha256`, no `command` / `description` field).
  local before_t13
  before_t13="$(count_audit_rows admin-1358 "$action")"
  local t13_canary='sk-ant-o-leak-canary-r3-fc52d'
  local credential_path="$BRIDGE_AGENT_HOME_ROOT/admin-1358/leak-target/.claude/.credentials.json"
  mkdir -p "$(dirname "$credential_path")"
  : >"$credential_path"
  # Point `claude_credential_paths()` at the smoke's fake credential
  # file so the credential-path argv gate trips on our T13 token-file
  # argument. The override flows into the Python hook via the env
  # because `run_pretool_hook` inherits the parent shell env (only
  # BRIDGE_AGENT_ID + BRIDGE_ADMIN_AGENT_ID are explicitly re-set).
  export BRIDGE_CLAUDE_TOKEN_REGISTRY="$credential_path"
  assert_hook_verdict \
    "T13 sanctioned shape + --token-file credential path (downstream deny)" \
    admin-1358 \
    "bash bridge-auth.sh claude-token add --stdin --token-file ${credential_path} <<< '${t13_canary}'" \
    "DENY" \
    "admin-1358"
  unset BRIDGE_CLAUDE_TOKEN_REGISTRY
  # Exemption row emitted (proves the carve-out fired and the deny is
  # the credential-path gate, NOT the substring gate).
  assert_audit_row_added \
    "T13 exemption emitted before downstream deny" admin-1358 "$action" "$before_t13"
  # Canary substring must not survive ANYWHERE in the audit log.
  if grep -q "leak-canary-r3-fc52d" "$audit"; then
    smoke_fail \
      "T13 token leakage: '${t13_canary}' appears in audit log after downstream deny: $(grep 'leak-canary-r3' "$audit")"
  else
    smoke_log "ok: T13 hash-only deny — '${t13_canary}' NOT in audit log"
  fi
  # The deny row (last `agent_tool_denied` for admin-1358) must carry
  # the hash-only summary, not raw `command` / `description`.
  local last_deny_row
  last_deny_row="$(grep '"action": "agent_tool_denied"' "$audit" | grep '"target": "admin-1358"' | tail -1)"
  if [[ -z "$last_deny_row" ]]; then
    smoke_fail "T13: cannot locate last agent_tool_denied row for admin-1358"
  fi
  if printf '%s' "$last_deny_row" | grep -Eq '"command_sha256": "[0-9a-f]{64}"'; then
    smoke_log "ok: T13 deny summary — command_sha256 present and 64-char hex"
  else
    smoke_fail "T13 deny summary: command_sha256 missing or wrong format — row=${last_deny_row}"
  fi
  # The deny row's summary must NOT carry raw command / description.
  # The summary is a JSON object; check that its `command` key is
  # absent. (The outer detail may carry other `command` keys via
  # nested structures, so grep for the precise `"command":` shape
  # inside summary by checking that the substring `"command":` does
  # not appear in the row.)
  if printf '%s' "$last_deny_row" | grep -q '"command":'; then
    smoke_fail "T13 deny summary: raw 'command' field present in deny row — row=${last_deny_row}"
  else
    smoke_log "ok: T13 deny summary — no raw 'command' field in agent_tool_denied row"
  fi
  if printf '%s' "$last_deny_row" | grep -q '"description":'; then
    smoke_fail "T13 deny summary: raw 'description' field present in deny row — row=${last_deny_row}"
  else
    smoke_log "ok: T13 deny summary — no raw 'description' field in agent_tool_denied row"
  fi

  # T14 — Codex r2 BLOCKING #1 r4 (2026-05-29) sealed: PostToolUse +
  # PostToolUseFailure audit rows also fed `tool_input["command"]` through
  # `tool_input_summary`, so a sanctioned-shape allowed credential
  # routine would write the raw heredoc-body OAuth token into the
  # `agent_tool_use` audit row after the PreToolUse exemption cleared.
  # The R2/R3 hash-only scrub on PreToolUse / deny paths only covered
  # the moment the carve-out fired or denied — once the carve-out
  # allowed execution, the PostToolUse hook landed the token next.
  # Drive the PostToolUse path directly and verify:
  #   (a) the audit log gains an `agent_tool_use` row for admin-1358;
  #   (b) the canary substring is NOT present anywhere in the log;
  #   (c) the row's `detail.summary` is the hash-only form
  #       (`command_sha256` 64-char hex, no raw `command` /
  #       `description`).
  # Repeat for `agent_tool_failure` via `PostToolUseFailure`.
  local t14_canary='sk-ant-o-posttool-canary-1f9c4e'
  local t14_command="bash bridge-auth.sh claude-token add --stdin --id pool-t14 <<< '${t14_canary}'"
  local t14_payload="$SMOKE_TMP_ROOT/payload-t14.json"
  local t14_esc
  t14_esc="$(json_escape "$t14_command")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PostToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${t14_esc}\"}," \
    "  \"tool_response\": {\"stdout\": \"ok\", \"stderr\": \"\"}," \
    "  \"tool_use_id\": \"smoke-1358-t14-$RANDOM\"," \
    '  "session_id": "smoke-session-t14"' \
    '}' \
    >"$t14_payload"
  local before_t14
  before_t14="$(count_audit_rows admin-1358 "agent_tool_use")"
  run_pretool_hook admin-1358 "$t14_payload" admin-1358 >/dev/null
  local after_t14
  after_t14="$(count_audit_rows admin-1358 "agent_tool_use")"
  if (( after_t14 > before_t14 )); then
    smoke_log "ok: T14 posttool audit row appended (before=${before_t14} after=${after_t14})"
  else
    smoke_fail "T14: expected new agent_tool_use audit row (before=${before_t14} after=${after_t14})"
  fi
  if grep -q "posttool-canary-1f9c4e" "$audit"; then
    smoke_fail \
      "T14 posttool token leakage: '${t14_canary}' appears in audit log: $(grep 'posttool-canary' "$audit")"
  else
    smoke_log "ok: T14 hash-only posttool — '${t14_canary}' NOT in audit log"
  fi
  local last_t14_row
  last_t14_row="$(grep '"action": "agent_tool_use"' "$audit" | grep '"target": "admin-1358"' | tail -1)"
  if [[ -z "$last_t14_row" ]]; then
    smoke_fail "T14: cannot locate last agent_tool_use row for admin-1358"
  fi
  if printf '%s' "$last_t14_row" | grep -Eq '"command_sha256": "[0-9a-f]{64}"'; then
    smoke_log "ok: T14 posttool summary — command_sha256 present and 64-char hex"
  else
    smoke_fail "T14 posttool summary: command_sha256 missing or wrong format — row=${last_t14_row}"
  fi
  if printf '%s' "$last_t14_row" | grep -q '"command":'; then
    smoke_fail "T14 posttool summary: raw 'command' field present in agent_tool_use row — row=${last_t14_row}"
  else
    smoke_log "ok: T14 posttool summary — no raw 'command' field in agent_tool_use row"
  fi
  if printf '%s' "$last_t14_row" | grep -q '"description":'; then
    smoke_fail "T14 posttool summary: raw 'description' field present in agent_tool_use row — row=${last_t14_row}"
  else
    smoke_log "ok: T14 posttool summary — no raw 'description' field in agent_tool_use row"
  fi

  # T14b — same scrub on `agent_tool_failure` via PostToolUseFailure.
  # A failed sanctioned-shape execution must also land hash-only.
  local t14b_canary='sk-ant-o-posttool-fail-canary-8d2b73'
  local t14b_command="bash bridge-auth.sh claude-token add --stdin --id pool-t14b <<< '${t14b_canary}'"
  local t14b_payload="$SMOKE_TMP_ROOT/payload-t14b.json"
  local t14b_esc
  t14b_esc="$(json_escape "$t14b_command")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PostToolUseFailure",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${t14b_esc}\"}," \
    "  \"error\": \"network unreachable\"," \
    "  \"is_interrupt\": false," \
    "  \"tool_use_id\": \"smoke-1358-t14b-$RANDOM\"," \
    '  "session_id": "smoke-session-t14b"' \
    '}' \
    >"$t14b_payload"
  local before_t14b
  before_t14b="$(count_audit_rows admin-1358 "agent_tool_failure")"
  run_pretool_hook admin-1358 "$t14b_payload" admin-1358 >/dev/null
  local after_t14b
  after_t14b="$(count_audit_rows admin-1358 "agent_tool_failure")"
  if (( after_t14b > before_t14b )); then
    smoke_log "ok: T14b posttool-failure audit row appended (before=${before_t14b} after=${after_t14b})"
  else
    smoke_fail "T14b: expected new agent_tool_failure audit row (before=${before_t14b} after=${after_t14b})"
  fi
  if grep -q "posttool-fail-canary-8d2b73" "$audit"; then
    smoke_fail \
      "T14b posttool-failure token leakage: '${t14b_canary}' appears in audit log: $(grep 'posttool-fail-canary' "$audit")"
  else
    smoke_log "ok: T14b hash-only posttool-failure — '${t14b_canary}' NOT in audit log"
  fi
  local last_t14b_row
  last_t14b_row="$(grep '"action": "agent_tool_failure"' "$audit" | grep '"target": "admin-1358"' | tail -1)"
  if [[ -z "$last_t14b_row" ]]; then
    smoke_fail "T14b: cannot locate last agent_tool_failure row for admin-1358"
  fi
  if printf '%s' "$last_t14b_row" | grep -Eq '"command_sha256": "[0-9a-f]{64}"'; then
    smoke_log "ok: T14b posttool-failure summary — command_sha256 present and 64-char hex"
  else
    smoke_fail "T14b posttool-failure summary: command_sha256 missing or wrong format — row=${last_t14b_row}"
  fi
  if printf '%s' "$last_t14b_row" | grep -q '"command":'; then
    smoke_fail "T14b posttool-failure summary: raw 'command' field present — row=${last_t14b_row}"
  else
    smoke_log "ok: T14b posttool-failure summary — no raw 'command' field"
  fi

  # T15 — Codex r2 BLOCKING (r3, 2026-05-29) broader leak: a NON-shape
  # credential mention. A bare `echo sk-ant-o-…` from a non-admin agent
  # is denied by `_raw_mentions_claude_credentials` but is NOT the
  # sanctioned routine shape, so the shape-only scrub missed it and the
  # raw token leaked into the `agent_tool_denied` summary. The fix gate
  # `_bash_audit_summary_needs_hashing` hashes on any credential marker,
  # not just the routine shape. Verify the deny row is hash-only and the
  # token canary is absent from the entire audit log.
  # Pass admin id = admin-1358 (NOT user-1358) so user-1358 is a genuine
  # non-admin. Otherwise the assert_hook_verdict default admin_id=$agent
  # would make user-1358 env-asserted admin, and `echo` is read-intent,
  # so the admin-credential-read carve-out would ALLOW it (masking the
  # non-shape leak this test targets).
  local t15_canary='sk-ant-o-nonshape-canary-1358'
  assert_hook_verdict \
    "T15 non-admin bare echo sk-ant-o (non-shape credential mention)" \
    user-1358 \
    "echo ${t15_canary}" \
    "DENY" \
    "admin-1358"
  if grep -q "nonshape-canary-1358" "$audit"; then
    smoke_fail \
      "T15 token leakage: non-shape credential mention leaked '${t15_canary}' into audit log: $(grep 'nonshape-canary-1358' "$audit")"
  else
    smoke_log "ok: T15 hash-only deny — '${t15_canary}' NOT in audit log (non-shape marker)"
  fi
  local last_t15_row
  last_t15_row="$(grep '"action": "agent_tool_denied"' "$audit" | grep '"target": "user-1358"' | tail -1)"
  if [[ -z "$last_t15_row" ]]; then
    smoke_fail "T15: cannot locate last agent_tool_denied row for user-1358"
  fi
  if printf '%s' "$last_t15_row" | grep -Eq '"command_sha256": "[0-9a-f]{64}"'; then
    smoke_log "ok: T15 deny summary — command_sha256 present and 64-char hex"
  else
    smoke_fail "T15 deny summary: command_sha256 missing or wrong format — row=${last_t15_row}"
  fi
  if printf '%s' "$last_t15_row" | grep -q '"command":'; then
    smoke_fail "T15 deny summary: raw 'command' field present in non-shape deny row — row=${last_t15_row}"
  else
    smoke_log "ok: T15 deny summary — no raw 'command' field in agent_tool_denied row"
  fi

  # T16 — Codex r2 BLOCKING (r3, 2026-05-29) NON-Bash leak: a Grep tool
  # whose `pattern` carries the OAuth token. `tool_input_summary` returns
  # the raw `pattern` for non-Bash tools, and the Bash hash-only scrub
  # does not cover it. The non-Bash deny branch now token-value-redacts
  # the summary (`_redact_credential_summary`). Drive a Grep PreToolUse
  # payload through the real hook and verify DENY + the token canary is
  # absent from the deny row / entire audit log.
  local t16_canary='sk-ant-o-grep-canary-1358'
  local t16_payload="$SMOKE_TMP_ROOT/payload-t16.json"
  write_grep_payload "$t16_payload" "$t16_canary"
  local t16_out
  t16_out="$(run_pretool_hook user-1358 "$t16_payload" admin-1358)"
  if [[ "$t16_out" == *'"permissionDecision": "deny"'* ]]; then
    smoke_log "ok: T16 non-Bash Grep credential pattern -> DENY"
  else
    smoke_fail "T16: expected DENY for Grep credential pattern, got: ${t16_out:-<empty>}"
  fi
  if grep -q "grep-canary-1358" "$audit"; then
    smoke_fail \
      "T16 token leakage: non-Bash Grep deny row leaked '${t16_canary}': $(grep 'grep-canary-1358' "$audit")"
  else
    smoke_log "ok: T16 non-Bash deny — '${t16_canary}' NOT in audit log"
  fi

  # T17 — Codex r3 BLOCKING (r4, 2026-05-29) the FOURTH writer in the
  # leak class. An admin Write to a protected system-config path
  # (agent-roster.local.sh) with the token in a NON-PATH field
  # (`content`) is correctly DENIED, but the INDEPENDENT
  # `system_config_mutation` audit row's non-Bash `operation` JSON
  # embedded the raw `content` value. The fix redacts token-shaped VALUES
  # in the non-Bash `operation` (and the `write_audit` choke-point is the
  # SSOT belt-and-suspenders). Drive a Write PreToolUse payload through
  # the real hook; assert DENY + the token canary is absent from the
  # `system_config_mutation` row / entire audit log, AND the file_path
  # anchor survives (path is not a secret).
  local t17_canary='sk-ant-o-system-config-content-canary-1358'
  local t17_payload="$SMOKE_TMP_ROOT/payload-t17.json"
  write_write_payload "$t17_payload" "$BRIDGE_ROSTER_LOCAL_FILE" "$t17_canary"
  local before_t17_scm
  before_t17_scm="$(count_audit_rows admin-1358 system_config_mutation)"
  local t17_out
  t17_out="$(run_pretool_hook admin-1358 "$t17_payload" admin-1358)"
  if [[ "$t17_out" == *'"permissionDecision": "deny"'* ]]; then
    smoke_log "ok: T17 admin Write to agent-roster.local.sh -> DENY"
  else
    smoke_fail "T17: expected DENY for admin Write to roster-local, got: ${t17_out:-<empty>}"
  fi
  assert_audit_row_added \
    "T17 system_config_mutation emit" admin-1358 system_config_mutation "$before_t17_scm"
  if grep -q "system-config-content-canary-1358" "$audit"; then
    smoke_fail \
      "T17 token leakage: system_config_mutation row leaked '${t17_canary}': $(grep 'system-config-content-canary-1358' "$audit")"
  else
    smoke_log "ok: T17 system_config_mutation — '${t17_canary}' NOT in audit log"
  fi
  # The file_path is a PATH not a secret — confirm it survives as a
  # forensic anchor in the system_config_mutation row.
  local last_t17_row
  last_t17_row="$(grep '"action": "system_config_mutation"' "$audit" | grep '"target": "admin-1358"' | tail -1)"
  if [[ -z "$last_t17_row" ]]; then
    smoke_fail "T17: cannot locate last system_config_mutation row for admin-1358"
  fi
  if printf '%s' "$last_t17_row" | grep -q 'agent-roster.local.sh'; then
    smoke_log "ok: T17 system_config_mutation — file_path anchor preserved"
  else
    smoke_fail "T17: file_path anchor missing from system_config_mutation row — row=${last_t17_row}"
  fi

  # T18 — sweep teeth (class closure). Enumerate every audit-writer code
  # path that can carry a `tool_input`-derived token and assert NO
  # `sk-ant-o…` canary survives ANYWHERE in audit.jsonl after driving all
  # of them. This is the non-vacuous guarantee that the whole class is
  # closed, not one more writer whacked. Each row uses a UNIQUE canary so
  # a survivor names exactly which writer leaked.
  #
  #   path A  Bash sanctioned-shape ALLOW  -> credential_routine_admin_exempted (hash-only)
  #   path B  Bash auth-verb via agb + token -> agent_tool_denied (the substring
  #           deny fires BEFORE the bridge-verb allowlist, so a token-bearing
  #           `agb auth claude-token add` is denied hash-only — the verb-allowed
  #           writer is token-free in practice but is redacted defensively too)
  #   path C  Bash non-shape mention DENY  -> agent_tool_denied (hash-only)
  #   path D  non-Bash Grep DENY           -> agent_tool_denied (token-value redacted)
  #   path E  non-Bash Write to roster     -> system_config_mutation + agent_tool_denied
  #   path F  Bash sanctioned ALLOW + PostToolUse -> agent_tool_use
  local sweep_token_prefix='sk-ant-o-sweep-canary-1358'
  # path A — admin sanctioned shape (here-string body carries token)
  local pa="$SMOKE_TMP_ROOT/payload-t18a.json"
  write_bash_payload "$pa" "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< '${sweep_token_prefix}-A'"
  run_pretool_hook admin-1358 "$pa" admin-1358 >/dev/null || true
  # path B — admin auth verb via agb (routes through verb-allowed audit)
  local pb="$SMOKE_TMP_ROOT/payload-t18b.json"
  write_bash_payload "$pb" "agb auth claude-token add --stdin --id pool-b <<< '${sweep_token_prefix}-B'"
  run_pretool_hook admin-1358 "$pb" admin-1358 >/dev/null || true
  # path C — non-admin bare mention (non-shape) -> hash-only deny
  local pc="$SMOKE_TMP_ROOT/payload-t18c.json"
  write_bash_payload "$pc" "echo ${sweep_token_prefix}-C"
  run_pretool_hook user-1358 "$pc" admin-1358 >/dev/null || true
  # path D — non-Bash Grep pattern naming the token
  local pd="$SMOKE_TMP_ROOT/payload-t18d.json"
  write_grep_payload "$pd" "${sweep_token_prefix}-D"
  run_pretool_hook user-1358 "$pd" admin-1358 >/dev/null || true
  # path E — admin Write to protected roster-local with token in content
  local pe="$SMOKE_TMP_ROOT/payload-t18e.json"
  write_write_payload "$pe" "$BRIDGE_ROSTER_LOCAL_FILE" "${sweep_token_prefix}-E"
  run_pretool_hook admin-1358 "$pe" admin-1358 >/dev/null || true
  # path F — admin sanctioned shape through PostToolUse (success row)
  local pf="$SMOKE_TMP_ROOT/payload-t18f.json"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PostToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"bash bridge-auth.sh claude-token add --stdin --id pool-f <<< '${sweep_token_prefix}-F'\"}," \
    "  \"tool_use_id\": \"smoke-1358-$RANDOM\"," \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$pf"
  run_pretool_hook admin-1358 "$pf" admin-1358 >/dev/null || true
  # Sweep assertion: NO sweep canary survives anywhere in the audit log.
  if grep -q "sweep-canary-1358" "$audit"; then
    smoke_fail \
      "T18 SWEEP token leakage: a sweep canary survived in audit log — $(grep 'sweep-canary-1358' "$audit")"
  else
    smoke_log "ok: T18 sweep — no 'sweep-canary-1358' survives in any audit row (class closed)"
  fi

  # T19 — PR #1790 r3 BLOCKING 2 (#1789): the daemon's limit-window-aware
  # rotate carries `--limited-until <ISO>` and the flag must be on the auth
  # allowlist or an admin agent mirroring the daemon's rotation is denied at
  # the hook. The validated surface is the anchored `agb`/`agent-bridge`
  # verb dispatcher (`auth claude-token rotate` → `_validate_auth_flags`);
  # the `bash bridge-auth.sh` spelling has no rotate carve-out and is out of
  # scope here. ISO values carry `:` and `+` which `_safe_slug_arg` rejects,
  # so the flag has its own strict timestamp predicate — verify the ALLOW
  # for the daemon-equivalent shape and the DENY for non-timestamp values
  # (the predicate must not become a free-text hole).
  assert_hook_verdict \
    "T19 rotate --limited-until ISO value" \
    admin-1358 \
    "agb auth claude-token rotate --if-auto-enabled --sync --reason usage:weekly:97 --limited-until 2099-01-02T03:04:05+09:00 --json" \
    "ALLOW"
  assert_hook_verdict \
    "T19 rotate --limited-until Z suffix" \
    admin-1358 \
    "agb auth claude-token rotate --limited-until 2099-01-02T03:04:05Z --json" \
    "ALLOW"
  assert_hook_verdict \
    "T19 rotate --limited-until date-only value denied" \
    admin-1358 \
    "agb auth claude-token rotate --limited-until 2099-01-02 --json" \
    "DENY"
  assert_hook_verdict \
    "T19 rotate --limited-until free text denied" \
    admin-1358 \
    "agb auth claude-token rotate --limited-until tomorrow --json" \
    "DENY"

  smoke_log "passed"
}

main "$@"
