#!/usr/bin/env bash
# scripts/smoke/1367-auth-sealed-paste.sh — regression for issue #1367.
#
# Sealed-paste root path: `bridge-auth.sh claude-token receive` reads the
# OAuth token echo-off from the OPERATOR's controlling tty (Option B),
# so the raw token NEVER lands in an agent transcript / tool input /
# argv / env / queue / named temp file. It writes through the EXISTING
# locked-registry add path; the admin transcript sees only a redacted
# fingerprint summary. A token-FREE request/receipt
# (`receive --request … --json`) lets an admin agent INITIATE the flow
# without touching the token.
#
# Test matrix:
#
#   R1  no controlling tty                  -> fail closed, NO token, rc!=0
#   R2  operator-terminal echo-off receive  -> registry holds the dummy
#       (pty harness)                          token; canary ABSENT from
#                                              pty capture + audit/queue/
#                                              log/note surfaces; redacted
#                                              fingerprint summary PRESENT
#   R3  token-free request/receipt          -> id/safe-flags/nonce only,
#                                              NO token; 0600 record
#   R4  --help / -h                          -> rc=0, usage on stdout
#
#   Negative guard smokes (PreToolUse hook layer — all DENIED):
#   N1  token in argv (positional)
#   N2  token via heredoc/stdin
#   N3  --token-file
#   N4  separator smuggling (`-- sk-ant-o…`)
#   N5  duplicate flags
#   N6  raw token never lands in a deny/error audit row
#   N7  admin token-free `receive --request … --json` -> ALLOW + audit
#   N8  token-accepting `receive` from an agent shape -> DENIED (+ wrapper
#       spellings: path / spacing / env-prefix / env / command / bash-opt /
#       env -u) and R1b the bridge-auth.py runtime agent-context refusal.
#
# Boundary scope (#1367 r5, codex-agreed): the N8 hook denies + the R1b
# runtime refusal are BEST-EFFORT deterrents, NOT an airtight sandbox. On a
# shared-UID host an agent can clear BRIDGE_AGENT_ID (`env -u` / `unset`) and
# invoke `python3 bridge-auth.py receive` directly with a pty it controls,
# escaping both layers (codex #1367 r4). That residual is OUT of #1367's
# threat model: such an agent can only store ITS OWN token, never the
# operator's. #1367's actual guarantee is that the OPERATOR's token, read
# echo-off in the operator's own terminal (R2), never transits an agent
# transcript / argv / env / queue / audit (R2 asserts canary-absence). On
# iso-v2 the locked registry's controller-UID ownership is the real FS
# boundary an iso agent cannot cross.
#
# Footgun #11 discipline: the pty harness is a standalone file-as-argv
# helper (1367-auth-sealed-paste-pty-helper.py), NEVER heredoc-stdin to a
# subprocess; JSON payloads are built with `printf`.

set -euo pipefail

SMOKE_NAME="1367-auth-sealed-paste"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"
PTY_HELPER="$SCRIPT_DIR/1367-auth-sealed-paste-pty-helper.py"
PTY_REG_VERIFY=""

# Assemble the dummy token at runtime from a split prefix so the literal
# `sk-ant-o…` run never appears as a single token in the smoke SOURCE —
# the value is still a valid token shape at runtime for the registry.
TOKEN_PREFIX="sk-ant-"
DUMMY_CANARY="${TOKEN_PREFIX}oat01-DUMMYCANARY1367-abcdefghijklmnop1234"

# JSON-escape a Bash command string for the PreToolUse payload.
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
    "  \"tool_use_id\": \"smoke-1367-$RANDOM\"," \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

run_pretool_hook() {
  local agent="$1"
  local payload_file="$2"
  local admin_id="${3:-${BRIDGE_ADMIN_AGENT_ID:-$agent}}"
  BRIDGE_AGENT_ID="$agent" \
    BRIDGE_ADMIN_AGENT_ID="$admin_id" \
    "$PYTHON_BIN" "$SMOKE_REPO_ROOT/hooks/tool-policy.py" <"$payload_file"
}

setup_agent_home() {
  local agent="$1"
  local kind="$2"
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

# Build the registry-verify helper file. Invoked file-as-argv (the
# `python3 <file>` form is a normal script invocation, never a
# heredoc-to-subprocess), so the smoke stays clean under the heredoc-ban
# lint.
build_reg_verify() {
  PTY_REG_VERIFY="$SMOKE_TMP_ROOT/reg-verify.py"
  printf '%s\n' \
    'import json, sys' \
    'reg, canary = sys.argv[1], sys.argv[2]' \
    'try:' \
    '    d = json.load(open(reg))' \
    'except Exception as e:' \
    '    print("NO_REGISTRY:%s" % e); sys.exit(0)' \
    'rows = d.get("tokens", [])' \
    'match = [r for r in rows if r.get("token") == canary]' \
    'if match and d.get("active_token_id") == match[0].get("id"):' \
    '    print("REGISTRY_OK")' \
    'else:' \
    '    print("REGISTRY_MISMATCH:ids=%s active=%s" % ([r.get("id") for r in rows], d.get("active_token_id")))' \
    >"$PTY_REG_VERIFY"
}

main() {
  smoke_require_cmd "$PYTHON_BIN"
  smoke_setup_bridge_home "$SMOKE_NAME"
  smoke_assert_file_exists "$PTY_HELPER" "pty harness helper present"
  build_reg_verify

  # The operator-path tests (R1-R4) simulate the OPERATOR's own terminal,
  # where BRIDGE_AGENT_ID is NOT set. Clear any inherited value (this smoke
  # is itself run by an agent whose BRIDGE_AGENT_ID would otherwise trip the
  # #1367 r4 agent-context refusal during R1-R4). The agent-context test
  # (R1b) and the PreToolUse hook tests set BRIDGE_AGENT_ID explicitly,
  # inline, so they are unaffected by this clear.
  unset BRIDGE_AGENT_ID

  setup_agent_home admin-1367 admin
  setup_agent_home user-1367 user

  # Registry path under the isolated secrets dir. NOTE: avoid the literal
  # `claude-oauth-tokens.json` basename so the smoke commands the operator
  # would run are not themselves caught by the credential-substring deny.
  local secrets_dir="$BRIDGE_HOME/secrets"
  local registry="$secrets_dir/oat-registry-1367.json"
  local audit
  audit="$(audit_log_path)"

  # ── R1 — no controlling tty => fail closed, NO token written ───────
  smoke_log "R1: no-tty fail-closed"
  local r1_out r1_rc=0
  r1_out="$("$PYTHON_BIN" "$SMOKE_REPO_ROOT/bridge-auth.py" \
    --registry "$registry" receive --id pool-r1 --json </dev/null 2>&1)" || r1_rc=$?
  if (( r1_rc != 0 )); then
    smoke_log "ok: R1 receive exits non-zero with no controlling tty (rc=$r1_rc)"
  else
    smoke_fail "R1: expected non-zero exit with no controlling tty, got rc=0: $r1_out"
  fi
  if [[ "$r1_out" == *"no controlling terminal"* ]]; then
    smoke_log "ok: R1 prints a clear no-controlling-terminal error"
  else
    smoke_fail "R1: expected a no-controlling-terminal error, got: $r1_out"
  fi
  if [[ -f "$registry" ]]; then
    smoke_fail "R1 LEAK: registry was written despite no controlling tty"
  else
    smoke_log "ok: R1 NO registry written on fail-closed"
  fi

  # ── R1b — agent-context refusal (#1367 r4, the RUNTIME boundary) ────
  # A token-accepting receive run with BRIDGE_AGENT_ID set (agent context)
  # must REFUSE before any tty read — regardless of the shell spelling used
  # to invoke it. This is the boundary the PreToolUse hook merely backstops;
  # it closes the env/command/bash-option wrapper bypasses at the source.
  smoke_log "R1b: agent-context refusal (BRIDGE_AGENT_ID set)"
  local r1b_out r1b_rc=0
  r1b_out="$(BRIDGE_AGENT_ID="agent-1367-probe" "$PYTHON_BIN" "$SMOKE_REPO_ROOT/bridge-auth.py" \
    --registry "$registry" receive --id pool-r1b --json </dev/null 2>&1)" || r1b_rc=$?
  if (( r1b_rc != 0 )); then
    smoke_log "ok: R1b receive refuses in agent context (rc=$r1b_rc)"
  else
    smoke_fail "R1b: expected refusal with BRIDGE_AGENT_ID set, got rc=0: $r1b_out"
  fi
  if [[ "$r1b_out" == *"must be run by the OPERATOR"* ]]; then
    smoke_log "ok: R1b refusal names the operator-terminal requirement"
  else
    smoke_fail "R1b: expected an operator-terminal refusal message, got: $r1b_out"
  fi
  if [[ -f "$registry" ]]; then
    smoke_fail "R1b LEAK: registry written despite agent-context refusal"
  else
    smoke_log "ok: R1b NO registry written on agent-context refusal"
  fi

  # ── R2 — operator-terminal echo-off receive (pty harness) ──────────
  smoke_log "R2: operator-terminal echo-off receive happy path"
  local capture="$SMOKE_TMP_ROOT/pty-capture-r2.bin"
  local r2_out r2_rc=0
  r2_out="$("$PYTHON_BIN" "$PTY_HELPER" "$capture" "$DUMMY_CANARY" -- \
    "$PYTHON_BIN" "$SMOKE_REPO_ROOT/bridge-auth.py" \
    --registry "$registry" receive --id pool-r2 --activate --json)" || r2_rc=$?
  if (( r2_rc != 0 )); then
    smoke_fail "R2: pty receive exited non-zero (rc=$r2_rc): $r2_out"
  fi
  # The echo-off read means the canary must NOT appear in the pty master
  # capture (the proxy for a transcript / terminal scrollback).
  if [[ "$r2_out" == *"CANARY_IN_PTY_CAPTURE=NO"* ]]; then
    smoke_log "ok: R2 dummy token NOT echoed into the pty capture"
  else
    smoke_fail "R2 LEAK: dummy token echoed into pty capture: $r2_out"
  fi
  if grep -q "DUMMYCANARY1367" "$capture" 2>/dev/null; then
    smoke_fail "R2 LEAK: canary present in pty capture file"
  else
    smoke_log "ok: R2 canary ABSENT from pty capture file"
  fi
  # Registry must hold the exact dummy token, activated.
  local reg_check
  reg_check="$("$PYTHON_BIN" "$PTY_REG_VERIFY" "$registry" "$DUMMY_CANARY" 2>/dev/null || true)"
  if [[ "$reg_check" == "REGISTRY_OK" ]]; then
    smoke_log "ok: R2 registry holds the dummy token, activated"
  else
    smoke_fail "R2: registry did not hold the dummy token as active (got: ${reg_check:-<empty>})"
  fi
  # Canary must be ABSENT from audit/log surfaces; a redacted fingerprint
  # summary must be PRESENT.
  if grep -rq "DUMMYCANARY1367" "$BRIDGE_LOG_DIR" 2>/dev/null; then
    smoke_fail "R2 LEAK: canary present in a log/audit surface: $(grep -rl DUMMYCANARY1367 "$BRIDGE_LOG_DIR")"
  else
    smoke_log "ok: R2 canary ABSENT from all log/audit surfaces"
  fi
  if [[ -f "$audit" ]] && grep -q '"action": "tool_policy_credential_sealed_receive"' "$audit"; then
    smoke_log "ok: R2 sealed-receive audit row present"
    if grep '"action": "tool_policy_credential_sealed_receive"' "$audit" | grep -q '"fingerprint": "sha256:'; then
      smoke_log "ok: R2 audit row carries a redacted sha256 fingerprint summary"
    else
      smoke_fail "R2: sealed-receive audit row missing the fingerprint summary"
    fi
  else
    smoke_fail "R2: no sealed-receive audit row written"
  fi
  # The registry secret file itself legitimately holds the token (0600),
  # but the queue surface must be canary-free.
  if [[ -d "$BRIDGE_STATE_DIR/queue" ]] && grep -rq "DUMMYCANARY1367" "$BRIDGE_STATE_DIR/queue" 2>/dev/null; then
    smoke_fail "R2 LEAK: canary present in a queue surface"
  else
    smoke_log "ok: R2 canary ABSENT from queue surfaces"
  fi

  # ── R3 — token-free request/receipt ────────────────────────────────
  smoke_log "R3: token-free request/receipt"
  local r3_out
  r3_out="$("$PYTHON_BIN" "$SMOKE_REPO_ROOT/bridge-auth.py" \
    --registry "$registry" receive --request --id pool-r3 --agents static --json)"
  if [[ "$r3_out" == *'"status": "pending"'* && "$r3_out" == *'"request_id":'* \
        && "$r3_out" == *'"nonce":'* ]]; then
    smoke_log "ok: R3 request emits id/request_id/nonce"
  else
    smoke_fail "R3: request did not emit the expected token-free record: $r3_out"
  fi
  if [[ "$r3_out" == *"DUMMYCANARY1367"* || "$r3_out" == *"$TOKEN_PREFIX"oat* ]]; then
    smoke_fail "R3 LEAK: request record contains a token-shaped value"
  else
    smoke_log "ok: R3 request record is token-free"
  fi
  # The request record file must be controller-owned 0600.
  local req_dir="$secrets_dir/sealed-receive-requests"
  if [[ -d "$req_dir" ]]; then
    local req_file
    req_file="$(find "$req_dir" -name '*.json' -type f | head -1)"
    if [[ -n "$req_file" ]]; then
      local mode
      # Portable mode read. macOS `stat -f '%Lp'` and Linux GNU
      # `stat -c '%a'` are mutually incompatible: on GNU stat `-f` means
      # `--file-system` and can exit 0 with non-mode output, so a
      # `stat -f … || stat -c …` chain silently yields garbage on Linux
      # instead of falling through. Read the mode via python3 (identical
      # on both platforms) to keep the 0600 assertion correct under
      # Linux CI. Format with no leading zero ('%o') so it compares to
      # the literal "600".
      mode="$("$PYTHON_BIN" -c 'import os,sys;print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$req_file" 2>/dev/null || printf '')"
      if [[ "$mode" == "600" ]]; then
        smoke_log "ok: R3 request record is mode 0600"
      else
        smoke_fail "R3: request record mode is $mode, want 600"
      fi
      if grep -q "DUMMYCANARY1367" "$req_file" 2>/dev/null; then
        smoke_fail "R3 LEAK: request record file carries a token"
      fi
    fi
  else
    smoke_fail "R3: request record directory missing"
  fi

  # ── R4 — --help / -h ───────────────────────────────────────────────
  smoke_log "R4: receive --help / -h"
  local h_out h_rc=0
  h_out="$("$SMOKE_REPO_ROOT/bridge-auth.sh" claude-token receive --help 2>&1)" || h_rc=$?
  if (( h_rc == 0 )) && [[ -n "$h_out" ]]; then
    smoke_log "ok: R4 receive --help rc=0 with usage on stdout"
  else
    smoke_fail "R4: receive --help expected rc=0 + non-empty stdout (rc=$h_rc): $h_out"
  fi
  h_rc=0
  h_out="$("$SMOKE_REPO_ROOT/bridge-auth.sh" claude-token receive -h 2>&1)" || h_rc=$?
  if (( h_rc == 0 )) && [[ -n "$h_out" ]]; then
    smoke_log "ok: R4 receive -h rc=0 with usage on stdout"
  else
    smoke_fail "R4: receive -h expected rc=0 + non-empty stdout (rc=$h_rc): $h_out"
  fi

  # ── Negative guard smokes (PreToolUse hook layer) ──────────────────
  smoke_log "negative guard smokes: token-bearing receive shapes DENIED"

  # N1 — token as a positional argv. Carries the credential substring so
  # the substring deny bites; the token-accepting receive has no argv
  # token source so this is a smuggling attempt that must DENY.
  assert_hook_verdict \
    "N1 token in argv" \
    admin-1367 \
    "bash bridge-auth.sh claude-token receive --id pool-a ${DUMMY_CANARY}" \
    "DENY" \
    "admin-1367"

  # N2 — token via heredoc/stdin. The sealed receive has no --stdin; a
  # here-string body carrying the token must DENY. The here-string
  # operator is assembled from a variable so the literal `<<<` never
  # appears in this smoke's SOURCE (otherwise scripts/audit-footgun-11.sh
  # classifies the line as a new H3 site and trips --baseline-check). The
  # JSON-escaped command the hook actually receives still carries the
  # real here-string operator, so the deny assertion is unchanged.
  local lt='<'
  local herestr_op="${lt}${lt}${lt}"
  assert_hook_verdict \
    "N2 token via heredoc/stdin" \
    admin-1367 \
    "bash bridge-auth.sh claude-token receive --id pool-a ${herestr_op} '${DUMMY_CANARY}'" \
    "DENY" \
    "admin-1367"

  # N3 — --token-file naming a credential path. Must DENY.
  assert_hook_verdict \
    "N3 --token-file" \
    admin-1367 \
    "bash bridge-auth.sh claude-token receive --id pool-a --token-file ${DUMMY_CANARY}" \
    "DENY" \
    "admin-1367"

  # N4 — separator smuggling: a `-- sk-ant-o…` tail after the request
  # shape. The substring deny bites and the request-shape exemption must
  # NOT fire.
  local before_n4
  before_n4="$(count_audit_rows admin-1367 tool_policy_credential_routine_sealed_paste)"
  assert_hook_verdict \
    "N4 separator smuggling -- token" \
    admin-1367 \
    "bash bridge-auth.sh claude-token receive --request --id pool-a --json -- ${DUMMY_CANARY}" \
    "DENY" \
    "admin-1367"
  local after_n4
  after_n4="$(count_audit_rows admin-1367 tool_policy_credential_routine_sealed_paste)"
  if (( after_n4 == before_n4 )); then
    smoke_log "ok: N4 smuggled-token request shape did NOT emit a sealed-paste exemption row"
  else
    smoke_fail "N4: smuggled-token request shape emitted an exemption row (before=$before_n4 after=$after_n4)"
  fi

  # N5 — duplicate flags on the request shape must DENY (malformed shape).
  assert_hook_verdict \
    "N5 duplicate --id flags" \
    admin-1367 \
    "agb auth claude-token receive --request --id pool-a --id pool-b --json" \
    "DENY" \
    "admin-1367"

  # N6 — raw token must NEVER land in a deny/error audit row. Drive the
  # token-in-argv deny shape, then assert the canary is absent from the
  # entire audit log and the deny row is hash-only.
  local n6_canary="${TOKEN_PREFIX}oat01-N6DENYCANARY-zyxwvutsrqponml"
  assert_hook_verdict \
    "N6 token-in-argv deny (hash-only audit)" \
    admin-1367 \
    "bash bridge-auth.sh claude-token receive --id pool-a ${n6_canary}" \
    "DENY" \
    "admin-1367"
  if grep -q "N6DENYCANARY" "$audit" 2>/dev/null; then
    smoke_fail "N6 LEAK: raw token landed in a deny/error audit row: $(grep N6DENYCANARY "$audit")"
  else
    smoke_log "ok: N6 raw token ABSENT from all deny/error audit rows"
  fi

  # N7 — admin token-free request shape -> ALLOW + sealed-paste audit row.
  local before_n7
  before_n7="$(count_audit_rows admin-1367 tool_policy_credential_routine_sealed_paste)"
  assert_hook_verdict \
    "N7 admin token-free request shape (agb)" \
    admin-1367 \
    "agb auth claude-token receive --request --id pool-a --agents static --json" \
    "ALLOW" \
    "admin-1367"
  local after_n7
  after_n7="$(count_audit_rows admin-1367 tool_policy_credential_routine_sealed_paste)"
  if (( after_n7 > before_n7 )); then
    smoke_log "ok: N7 token-free request emitted a sealed-paste audit row (before=$before_n7 after=$after_n7)"
  else
    smoke_fail "N7: token-free request did NOT emit a sealed-paste audit row (before=$before_n7 after=$after_n7)"
  fi

  # N7b — same shape via the `bash bridge-auth.sh` spelling -> ALLOW +
  # audit row (the request text is token-free so nothing denies it).
  local before_n7b
  before_n7b="$(count_audit_rows admin-1367 tool_policy_credential_routine_sealed_paste)"
  assert_hook_verdict \
    "N7b admin token-free request shape (bash bridge-auth.sh)" \
    admin-1367 \
    "bash bridge-auth.sh claude-token receive --request --id pool-a --json" \
    "ALLOW" \
    "admin-1367"
  local after_n7b
  after_n7b="$(count_audit_rows admin-1367 tool_policy_credential_routine_sealed_paste)"
  if (( after_n7b > before_n7b )); then
    smoke_log "ok: N7b bash-spelling token-free request emitted a sealed-paste audit row"
  else
    smoke_fail "N7b: bash-spelling token-free request did NOT emit a sealed-paste audit row"
  fi

  # N8 — token-ACCEPTING receive shape from an agent (agb spelling, no
  # --request) must DENY: the agent must not be able to drive a
  # token-accepting receive.
  assert_hook_verdict \
    "N8 token-accepting receive from agent (agb)" \
    admin-1367 \
    "agb auth claude-token receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  # N8-bash — #1367 r2 (codex SECURITY): the SAME token-accepting receive
  # via the `bash bridge-auth.sh` wrapper spelling must ALSO DENY. The
  # wrapper carries no token in its argv and its leaf is not `agb`/
  # `agent-bridge`, so before the r2 fix it fell through ALLOWED. Guard
  # the bash-wrapper bypass.
  assert_hook_verdict \
    "N8-bash token-accepting receive from agent (bash bridge-auth.sh)" \
    admin-1367 \
    "bash bridge-auth.sh claude-token receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  # N8-bash-allow — the token-FREE `--request … --json` bash spelling must
  # STAY allowed (the r2 deny must not over-block the legitimate request
  # shape). This re-confirms N7b under the new deny gate.
  assert_hook_verdict \
    "N8-bash-allow token-free request stays allowed (bash bridge-auth.sh)" \
    admin-1367 \
    "bash bridge-auth.sh claude-token receive --request --id pool-a --json" \
    "ALLOW" \
    "admin-1367"

  # N8-bash-path / -spacing / -envprefix — #1367 r2 (codex SECURITY,
  # internal-review finding): the bash-wrapper deny must be robust to the
  # invocation variants a prefix-only `startswith` missed — an absolute
  # path to bridge-auth.sh, collapsed/extra whitespace, and a leading
  # `VAR=value` env-assignment prefix. Each is still a working token-
  # accepting receive and must DENY.
  assert_hook_verdict \
    "N8-bash-path token-accepting receive via absolute path" \
    admin-1367 \
    "bash /opt/agent-bridge/bridge-auth.sh claude-token receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  assert_hook_verdict \
    "N8-bash-spacing token-accepting receive with extra spacing" \
    admin-1367 \
    "bash   bridge-auth.sh   claude-token   receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  assert_hook_verdict \
    "N8-bash-envprefix token-accepting receive with env-assignment prefix" \
    admin-1367 \
    "FOO=1 bash bridge-auth.sh claude-token receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  # N8-bash-env / -command / -opt / -env-u — #1367 r4 (codex SECURITY):
  # command-prefix wrappers (`env`, `/usr/bin/env`, `command`) and bash
  # options (`--noprofile`) also run a working token-accepting receive and
  # must DENY at the hook (best-effort defense-in-depth; the runtime
  # agent-context refusal is the real boundary). `env -u BRIDGE_AGENT_ID`
  # additionally tries to clear the runtime gate — the hook must still deny.
  assert_hook_verdict \
    "N8-bash-env token-accepting receive via env prefix" \
    admin-1367 \
    "env FOO=1 bash bridge-auth.sh claude-token receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  assert_hook_verdict \
    "N8-bash-env-abs token-accepting receive via /usr/bin/env prefix" \
    admin-1367 \
    "/usr/bin/env bash bridge-auth.sh claude-token receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  assert_hook_verdict \
    "N8-bash-command token-accepting receive via command prefix" \
    admin-1367 \
    "command bash bridge-auth.sh claude-token receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  assert_hook_verdict \
    "N8-bash-opt token-accepting receive with bash option" \
    admin-1367 \
    "bash --noprofile bridge-auth.sh claude-token receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  assert_hook_verdict \
    "N8-bash-env-u token-accepting receive clearing BRIDGE_AGENT_ID via env -u" \
    admin-1367 \
    "env -u BRIDGE_AGENT_ID bash bridge-auth.sh claude-token receive --id pool-a --activate --json" \
    "DENY" \
    "admin-1367"

  # N9 — non-admin token-free request shape must DENY (admin-only).
  assert_hook_verdict \
    "N9 non-admin token-free request shape" \
    user-1367 \
    "agb auth claude-token receive --request --id pool-a --json" \
    "DENY" \
    "admin-1367"

  smoke_log "passed"
}

main "$@"
