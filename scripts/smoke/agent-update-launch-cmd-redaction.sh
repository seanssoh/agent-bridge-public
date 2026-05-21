#!/usr/bin/env bash
# scripts/smoke/agent-update-launch-cmd-redaction.sh — Issue #1023 smoke.
#
# `agent-bridge agent update --launch-cmd-*` echoes the before/after
# launch command, the operation summary, the recorded add-env actions,
# the audit detail, the --json envelope, the plain-text result, and the
# dry-run output. A launch command's leading env-prefix routinely
# carries credential-bearing values (OAuth / MS365 client secrets,
# bearer tokens). This smoke pins that the raw secret literal survives
# in NONE of those surfaces, while a benign env value is left intact and
# the actually-applied launch command on disk still carries the real
# value.
#
# Surfaces asserted (codex r1 — redacting only before/after diff is
# insufficient):
#   - before_launch_cmd / after_launch_cmd diff (plain text)
#   - --json envelope (before/after launch_cmd + actions)
#   - operation_summary + audit detail (audit.jsonl)
#   - recorded add-env actions
#   - dry-run output (default + --json modes)
#
# Caller-source trust is forced via BRIDGE_CALLER_SOURCE=operator-tui so
# the smoke does not depend on a real TTY (CI / pipe execution).

set -euo pipefail

SMOKE_NAME="agent-update-launch-cmd-redaction"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

ADMIN="testadmin"
WORKER="testworker"

# The secret literals. These must never appear in any rendered output.
SECRET_VALUE="supersecretClientSecretXYZ"
BEARER_VALUE="BearerTok-abc123def456"
# A sensitive value that CONTAINS a comma — `--launch-cmd-add-env` only
# rejects newlines, so a comma is a valid value char. The redactor must
# redact the whole value structurally; a post-comma-join redactor would
# strand SECRET_VALUE (the suffix) as a bare token (issue #1023 codex
# r1 BLOCKING).
COMMA_SECRET_VALUE="left,${SECRET_VALUE}"
# A benign env value — must survive un-redacted in the diff.
BENIGN_VALUE="benign-debug-flag-99"

write_roster_fixture() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID=${ADMIN}
# BEGIN AGENT BRIDGE MANAGED ROLE: ${ADMIN}
bridge_add_agent_id_if_missing ${ADMIN}
BRIDGE_AGENT_DESC["${ADMIN}"]='admin role'
BRIDGE_AGENT_ENGINE["${ADMIN}"]='claude'
BRIDGE_AGENT_SESSION["${ADMIN}"]='${ADMIN}'
BRIDGE_AGENT_WORKDIR["${ADMIN}"]='${BRIDGE_AGENT_HOME_ROOT}/${ADMIN}'
BRIDGE_AGENT_SOURCE["${ADMIN}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${ADMIN}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${ADMIN}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${ADMIN}

# BEGIN AGENT BRIDGE MANAGED ROLE: ${WORKER}
bridge_add_agent_id_if_missing ${WORKER}
BRIDGE_AGENT_DESC["${WORKER}"]='worker role'
BRIDGE_AGENT_ENGINE["${WORKER}"]='claude'
BRIDGE_AGENT_SESSION["${WORKER}"]='${WORKER}'
BRIDGE_AGENT_WORKDIR["${WORKER}"]='${BRIDGE_AGENT_HOME_ROOT}/${WORKER}'
BRIDGE_AGENT_SOURCE["${WORKER}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${WORKER}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${WORKER}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${WORKER}
EOF
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$WORKER" "$BRIDGE_AGENT_HOME_ROOT/$ADMIN"
}

run_update() {
  # Run as admin from operator-trusted source. $@ supplies mode flags
  # (--json / --dry-run) and the launch-cmd mutation flags.
  BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_AGENT_ID="$ADMIN" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" update "$WORKER" "$@"
}

read_launch_line() {
  grep "^BRIDGE_AGENT_LAUNCH_CMD\\[\"${WORKER}\"\\]=" \
    "$BRIDGE_ROSTER_LOCAL_FILE" | head -n 1
}

# assert_no_secret <label> <text>
# Fail if either secret literal appears anywhere in <text>.
assert_no_secret() {
  local label="$1"
  local text="$2"
  if [[ "$text" == *"$SECRET_VALUE"* ]]; then
    smoke_fail "secret literal leaked into $label: $text"
  fi
  if [[ "$text" == *"$BEARER_VALUE"* ]]; then
    smoke_fail "bearer token literal leaked into $label: $text"
  fi
}

assert_default_text_redacts_secret() {
  # Default (non-JSON) plain-text output across two sensitive env adds.
  local output
  output="$(run_update \
    --launch-cmd-add-env "MS365_CLIENT_SECRET=${SECRET_VALUE}" \
    --launch-cmd-add-env "AUTHORIZATION=${BEARER_VALUE}")"

  assert_no_secret "plain-text result" "$output"
  smoke_assert_contains "$output" "MS365_CLIENT_SECRET=" \
    "plain-text result still shows the redacted key name"
  smoke_assert_contains "$output" "***REDACTED***" \
    "plain-text result shows the redaction placeholder"

  # The roster on disk must still carry the REAL secret — redaction is
  # output-rendering only.
  local line
  line="$(read_launch_line)"
  smoke_assert_contains "$line" "$SECRET_VALUE" \
    "applied launch_cmd on disk still carries the real secret value"
  smoke_assert_contains "$line" "$BEARER_VALUE" \
    "applied launch_cmd on disk still carries the real bearer token"
}

assert_json_redacts_secret() {
  # --json envelope: before/after launch_cmd + actions array.
  local output
  output="$(run_update --json \
    --launch-cmd-add-env "REFRESH_TOKEN=${SECRET_VALUE}")"

  assert_no_secret "--json envelope" "$output"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
secret = sys.argv[2]
blob = json.dumps(payload)
assert secret not in blob, f"secret in --json payload: {payload}"
assert "REFRESH_TOKEN=" in payload["after"]["launch_cmd"], payload
assert "***REDACTED***" in payload["after"]["launch_cmd"], payload
# Recorded add-env action must be redacted too.
joined = " ".join(a for a in payload["actions"] if isinstance(a, str))
assert "add-env REFRESH_TOKEN=" in joined, payload
assert secret not in joined, payload
' "$output" "$SECRET_VALUE"
}

assert_benign_env_not_redacted() {
  # A non-sensitive key (BRIDGE_HOME / DEBUG) must NOT be redacted —
  # the diff signal for benign env stays intact.
  local output
  output="$(run_update --json \
    --launch-cmd-add-env "DEBUG=${BENIGN_VALUE}")"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
benign = sys.argv[1 + 1]
assert benign in payload["after"]["launch_cmd"], payload
joined = " ".join(a for a in payload["actions"] if isinstance(a, str))
assert f"add-env DEBUG={benign}" in joined, payload
' "$output" "$BENIGN_VALUE"
  # Clean up the benign add so downstream assertions start clean.
  run_update --json --launch-cmd-remove-env DEBUG >/dev/null
}

assert_audit_log_redacts_secret() {
  # The audit log carries the operation summary + detail (before/after
  # launch_cmd, actions). The SHA chain is the tamper-evidence; the raw
  # secret must not be in the JSONL.
  : >"$BRIDGE_AUDIT_LOG" 2>/dev/null || true
  run_update --json \
    --launch-cmd-add-env "CLIENT_SECRET=${SECRET_VALUE}" >/dev/null
  if [[ ! -s "$BRIDGE_AUDIT_LOG" ]]; then
    smoke_fail "expected an audit row after a launch-cmd mutation"
  fi
  local audit_blob
  audit_blob="$(cat "$BRIDGE_AUDIT_LOG")"
  assert_no_secret "audit.jsonl" "$audit_blob"
  smoke_assert_contains "$audit_blob" "CLIENT_SECRET" \
    "audit detail still records which key changed"
  smoke_assert_contains "$audit_blob" "***REDACTED***" \
    "audit detail carries the redaction placeholder"
}

assert_dry_run_redacts_secret() {
  # Dry-run output (default + --json). The roster must not change AND
  # the planned secret must not appear in the dry-run render.
  local before_line output
  before_line="$(read_launch_line)"

  output="$(run_update --dry-run \
    --launch-cmd-add-env "API_KEY=${SECRET_VALUE}")"
  assert_no_secret "dry-run plain-text output" "$output"
  smoke_assert_contains "$output" "dry_run: yes" "dry-run flag echoed"
  smoke_assert_contains "$output" "***REDACTED***" \
    "dry-run plain-text output is redacted"

  output="$(run_update --json --dry-run \
    --launch-cmd-add-env "API_KEY=${SECRET_VALUE}")"
  assert_no_secret "dry-run --json output" "$output"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["dry_run"] is True, payload
assert sys.argv[2] not in json.dumps(payload), payload
' "$output" "$SECRET_VALUE"

  local after_line
  after_line="$(read_launch_line)"
  smoke_assert_eq "$before_line" "$after_line" \
    "dry-run did not mutate the roster launch_cmd line"
}

assert_comma_value_secret_redacted_everywhere() {
  # Issue #1023 codex r1 BLOCKING regression: a sensitive add-env value
  # containing a comma. The operation summary is built by comma-joining
  # the op stream; redacting AFTER that join split the value at its
  # comma and let the suffix (SECRET_VALUE) survive as a bare token in
  # the audit `operation` string. The redactor now operates on the
  # structured op, so the whole value — comma and all — is redacted in
  # EVERY surface: --json, plain text, audit detail, operation summary,
  # actions, dry-run.
  : >"$BRIDGE_AUDIT_LOG" 2>/dev/null || true

  # --json + plain text in one apply run (default mode prints text).
  local output
  output="$(run_update \
    --launch-cmd-add-env "MS365_CLIENT_SECRET=${COMMA_SECRET_VALUE}")"
  assert_no_secret "comma-value plain-text result" "$output"
  smoke_assert_contains "$output" "***REDACTED***" \
    "comma-value plain-text result is redacted"

  output="$(run_update --json --launch-cmd-remove-env MS365_CLIENT_SECRET)"
  # Re-add via --json so we can assert the envelope too.
  output="$(run_update --json \
    --launch-cmd-add-env "MS365_CLIENT_SECRET=${COMMA_SECRET_VALUE}")"
  assert_no_secret "comma-value --json envelope" "$output"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
suffix = sys.argv[2]
blob = json.dumps(payload)
assert suffix not in blob, f"comma-value secret suffix in --json: {payload}"
assert "MS365_CLIENT_SECRET=" in payload["after"]["launch_cmd"], payload
assert "***REDACTED***" in payload["after"]["launch_cmd"], payload
joined = " ".join(a for a in payload["actions"] if isinstance(a, str))
assert suffix not in joined, payload
' "$output" "$SECRET_VALUE"

  # Audit log: the `operation` summary string is the surface the
  # post-join redactor leaked through. Assert the suffix is gone there.
  if [[ ! -s "$BRIDGE_AUDIT_LOG" ]]; then
    smoke_fail "expected an audit row after a comma-value launch-cmd mutation"
  fi
  local audit_blob
  audit_blob="$(cat "$BRIDGE_AUDIT_LOG")"
  assert_no_secret "comma-value audit.jsonl" "$audit_blob"
  # Explicitly pull the audit `operation` field and assert the suffix
  # is absent — this is the exact field the lossy comma-join leaked.
  python3 -c '
import json, sys
suffix = sys.argv[2]
for line in sys.argv[1].splitlines():
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    detail = row.get("detail") or {}
    op = detail.get("operation", "")
    assert suffix not in op, f"comma-value secret suffix in audit operation: {op!r}"
' "$audit_blob" "$SECRET_VALUE"
  smoke_assert_contains "$audit_blob" "MS365_CLIENT_SECRET" \
    "comma-value audit detail still records which key changed"

  # Dry-run must redact the comma value too.
  output="$(run_update --dry-run \
    --launch-cmd-add-env "MS365_CLIENT_SECRET=${COMMA_SECRET_VALUE}")"
  assert_no_secret "comma-value dry-run output" "$output"

  # The applied launch command on disk still carries the REAL comma
  # value — redaction is output-rendering only.
  local line
  line="$(read_launch_line)"
  smoke_assert_contains "$line" "$COMMA_SECRET_VALUE" \
    "applied launch_cmd on disk still carries the real comma value"

  # Clean up so downstream assertions start from a known state.
  run_update --json --launch-cmd-remove-env MS365_CLIENT_SECRET >/dev/null
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd bash
  smoke_setup_bridge_home "agent-update-launch-cmd-redaction"
  write_roster_fixture
  smoke_run "default plain-text output redacts secret env values" \
    assert_default_text_redacts_secret
  smoke_run "--json envelope redacts launch_cmd + actions" \
    assert_json_redacts_secret
  smoke_run "benign env value is left un-redacted" \
    assert_benign_env_not_redacted
  smoke_run "audit log redacts secret env values" \
    assert_audit_log_redacts_secret
  smoke_run "dry-run output (default + --json) redacts secret" \
    assert_dry_run_redacts_secret
  smoke_run "comma-containing secret value redacted in every surface" \
    assert_comma_value_secret_redacted_everywhere
  smoke_log "passed"
}

main "$@"
