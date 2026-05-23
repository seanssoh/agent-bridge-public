#!/usr/bin/env bash
# scripts/smoke/1136-always-on-no.sh — Issue #1136 smoke.
#
# Issue #1093 / PR #1102 (v0.14.5-beta6) added `--idle-timeout`,
# `--loop yes|no`, and `--always-on yes` to `agent update` and
# `agent add`. The symmetric `--always-on no` direction was deferred
# because missing `BRIDGE_AGENT_IDLE_TIMEOUT` reads as `0` (always-on)
# by default, so a bare `--always-on no` would be ambiguous.
#
# This issue closes that loop:
#  - `--always-on no` is accepted only when `--idle-timeout <N>` is
#    also present AND `<N>` is a positive integer. Otherwise the CLI
#    rejects at parse time with a deterministic deny string.
#  - The numeric persistence is identical to a bare `--idle-timeout <N>`
#    invocation. The `--always-on no` flag itself adds NO persistence
#    side effect.
#  - The audit envelope + `--json` envelope gain an `expressed_intent`
#    field recording the operator's declarative direction:
#       `--always-on yes`            -> expressed_intent=always_on_yes
#       legacy bare `--always-on`    -> expressed_intent=always_on_yes
#       `--always-on no`             -> expressed_intent=always_on_no
#       bare `--idle-timeout <N>`    -> expressed_intent absent
#    The field is recorded EVEN ON `changed=false` no-op mutations so a
#    policy re-affirmation call still produces a searchable audit row.
#
# Test matrix (T1-T6 per fixer brief):
#
#  T1. `--always-on no --idle-timeout 900` from current always-on state
#      -> roster carries IDLE_TIMEOUT=900, JSON envelope reports
#         changed=true / before.idle_timeout=0 / after.idle_timeout=900
#         / expressed_intent=always_on_no, and the audit row carries
#         expressed_intent=always_on_no with the same numeric deltas.
#
#  T2. `--always-on no` without `--idle-timeout` rejects at parse time
#      with the exact English deny string the brief specifies.
#
#  T3. `--always-on no --idle-timeout 0` rejects at parse time
#      (contradictory: --always-on yes is the always-on direction).
#
#  T4. `--always-on yes` (no idle-timeout co-flag) records
#      expressed_intent=always_on_yes on the audit row AND the JSON
#      envelope.
#
#  T5. Bare `--idle-timeout 900` (no --always-on co-flag) does NOT
#      record expressed_intent — the operator did not declare a
#      direction; only the numeric delta is captured.
#
#  T6. No-op `--always-on no --idle-timeout 900` against an agent
#      already at IDLE_TIMEOUT=900 still lands an audit row with
#      expressed_intent=always_on_no and changed=false.
#
# Plus a parallel `agent add` (create-side) coverage:
#  T7. `agent add ... --always-on no --idle-timeout 900` requires the
#      same co-flag and produces an audit row with
#      expressed_intent=always_on_no on the create-side envelope.

set -euo pipefail

SMOKE_NAME="1136-always-on-no"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

ADMIN="testadmin"
WORKER="testworker"

write_roster_fixture() {
  # Seed agent-roster.local.sh with an admin + a worker that is
  # implicitly always-on (no BRIDGE_AGENT_IDLE_TIMEOUT line, which reads
  # as 0 — the case the issue specifically targets).
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
  : >"$BRIDGE_AUDIT_LOG"
}

run_update() {
  BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_AGENT_ID="$ADMIN" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" update "$WORKER" --json "$@"
}

run_create() {
  BRIDGE_CALLER_SOURCE="operator-tui" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" create "$@" 2>&1
}

read_idle_timeout_line() {
  grep "^BRIDGE_AGENT_IDLE_TIMEOUT\\[\"${WORKER}\"\\]=" \
    "$BRIDGE_ROSTER_LOCAL_FILE" | head -n 1
}

# Lift the last system_config_mutation audit row's detail JSON whose
# trigger matches the supplied string (agent-update-apply /
# agent-update-dry-run / agent-create-apply). Empty result -> stderr +
# rc=1 so the smoke fails fast on a missing audit row rather than
# silently misinterpreting an empty detail.
last_audit_detail_for_trigger() {
  local trigger="$1"
  python3 "$SCRIPT_DIR/1105-helpers/last-create-audit-detail.py" \
    "$BRIDGE_AUDIT_LOG" >/dev/null 2>&1 || true
  # Re-use the same JSONL walker shape as 1105-helpers but filtered on
  # the supplied trigger. Inlined here (file-as-argv via -c) to keep the
  # new helper count from growing; the body is tiny and side-effect-free.
  python3 -c '
import json, sys
path, want = sys.argv[1], sys.argv[2]
last = None
try:
    fh = open(path, encoding="utf-8")
except FileNotFoundError:
    sys.exit(1)
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("action") != "system_config_mutation":
            continue
        detail = row.get("detail")
        if isinstance(detail, str):
            try:
                detail = json.loads(detail)
            except ValueError:
                continue
        if not isinstance(detail, dict):
            continue
        if detail.get("trigger") != want:
            continue
        last = detail
if last is None:
    sys.exit(1)
print(json.dumps(last, ensure_ascii=True, sort_keys=True))
' "$BRIDGE_AUDIT_LOG" "$trigger"
}

# T1: --always-on no --idle-timeout 900 from current always-on state.
test_t1_always_on_no_with_positive_idle_timeout() {
  write_roster_fixture
  local out
  out="$(run_update --always-on no --idle-timeout 900)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
assert payload["before"]["idle_timeout"] == "0", payload
assert payload["after"]["idle_timeout"] == "900", payload
assert payload.get("expressed_intent") == "always_on_no", payload
' "$out"

  local line
  line="$(read_idle_timeout_line)"
  smoke_assert_contains "$line" '="900"' "T1: roster carries IDLE_TIMEOUT=900"

  local detail
  detail="$(last_audit_detail_for_trigger agent-update-apply)" \
    || smoke_fail "T1: no agent-update-apply audit row found"
  python3 -c '
import json, sys
detail = json.loads(sys.argv[1])
assert detail.get("expressed_intent") == "always_on_no", detail
assert detail.get("before_idle_timeout") == "0", detail
assert detail.get("after_idle_timeout") == "900", detail
' "$detail"
}

# T2: --always-on no without --idle-timeout rejects with the exact
# deny string the brief specifies.
test_t2_always_on_no_requires_idle_timeout() {
  write_roster_fixture
  local rc=0 err
  set +e
  err="$(run_update --always-on no 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "T2: expected --always-on no without --idle-timeout to be refused; out=$err"
  fi
  smoke_assert_contains "$err" \
    "--always-on no requires --idle-timeout <seconds> (positive integer)" \
    "T2: exact English deny string surfaces"
}

# T3: --always-on no --idle-timeout 0 rejects (contradictory).
test_t3_always_on_no_zero_idle_timeout_rejected() {
  write_roster_fixture
  local rc=0 err
  set +e
  err="$(run_update --always-on no --idle-timeout 0 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "T3: expected --always-on no + --idle-timeout 0 to be refused; out=$err"
  fi
  smoke_assert_contains "$err" \
    "--always-on no with --idle-timeout 0 is contradictory" \
    "T3: contradictory-combination deny string surfaces"
}

# T4: --always-on yes records expressed_intent on audit + JSON envelope.
test_t4_always_on_yes_records_intent() {
  write_roster_fixture
  local out
  out="$(run_update --always-on yes)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload.get("expressed_intent") == "always_on_yes", payload
assert payload["after"]["idle_timeout"] == "0", payload
' "$out"

  local detail
  detail="$(last_audit_detail_for_trigger agent-update-apply)" \
    || smoke_fail "T4: no agent-update-apply audit row found"
  python3 -c '
import json, sys
detail = json.loads(sys.argv[1])
assert detail.get("expressed_intent") == "always_on_yes", detail
' "$detail"
}

# T5: bare --idle-timeout 900 does NOT record expressed_intent
# (no operator-declared direction; only the numeric delta is captured).
test_t5_bare_idle_timeout_omits_intent() {
  write_roster_fixture
  local out
  out="$(run_update --idle-timeout 900)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is True, payload
assert payload["after"]["idle_timeout"] == "900", payload
assert "expressed_intent" not in payload, payload
' "$out"

  local detail
  detail="$(last_audit_detail_for_trigger agent-update-apply)" \
    || smoke_fail "T5: no agent-update-apply audit row found"
  python3 -c '
import json, sys
detail = json.loads(sys.argv[1])
assert "expressed_intent" not in detail, detail
' "$detail"
}

# T6: no-op --always-on no --idle-timeout 900 against an agent already
# at IDLE_TIMEOUT=900 still lands an audit row with
# expressed_intent=always_on_no and changed=false. The whole point of
# `expressed_intent` is to clarify exactly this re-affirmation case.
test_t6_noop_still_records_intent() {
  write_roster_fixture
  # First, persist 900 with no --always-on flag (so expressed_intent is
  # absent and the next call's no-op short-circuit will fire).
  run_update --idle-timeout 900 >/dev/null
  # Clear the audit log so the no-op assertion below cannot reach back
  # to the priming call's row by accident.
  : >"$BRIDGE_AUDIT_LOG"

  local out
  out="$(run_update --always-on no --idle-timeout 900)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["changed"] is False, payload
assert payload.get("expressed_intent") == "always_on_no", payload
# Numeric values match (no real delta) but the audit envelope still
# surfaces them because --idle-timeout was passed.
assert payload["before"]["idle_timeout"] == "900", payload
assert payload["after"]["idle_timeout"] == "900", payload
' "$out"

  local detail
  detail="$(last_audit_detail_for_trigger agent-update-apply)" \
    || smoke_fail "T6: no agent-update-apply audit row found for no-op re-affirmation"
  python3 -c '
import json, sys
detail = json.loads(sys.argv[1])
assert detail.get("expressed_intent") == "always_on_no", detail
' "$detail"
}

# T7: agent add (create-side) parses --always-on no the same way, and
# the create-side audit row carries expressed_intent=always_on_no.
test_t7_agent_add_always_on_no() {
  write_roster_fixture
  # Rejection without --idle-timeout on the create side.
  local rc=0 err
  set +e
  err="$(run_create createworker --engine claude --always-on no 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "T7: expected create --always-on no without --idle-timeout to be refused; out=$err"
  fi
  smoke_assert_contains "$err" \
    "--always-on no requires --idle-timeout <seconds> (positive integer)" \
    "T7: create-side deny string matches the brief contract"

  # And the happy path with the explicit co-flag.
  local out
  out="$(run_create createworker --engine claude --always-on no --idle-timeout 600 --json)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["agent"] == "createworker", payload
assert payload["policy"]["idle_timeout"] == "600", payload
assert payload["policy"].get("expressed_intent") == "always_on_no", payload
' "$out"

  local detail
  detail="$(last_audit_detail_for_trigger agent-create-apply)" \
    || smoke_fail "T7: no agent-create-apply audit row found"
  python3 -c '
import json, sys
detail = json.loads(sys.argv[1])
assert detail.get("expressed_intent") == "always_on_no", detail
assert detail.get("after_idle_timeout") == "600", detail
' "$detail"
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd bash
  smoke_setup_bridge_home "$SMOKE_NAME"
  smoke_run "T1: --always-on no + --idle-timeout 900 persists + intent" test_t1_always_on_no_with_positive_idle_timeout
  smoke_run "T2: --always-on no without --idle-timeout rejects"         test_t2_always_on_no_requires_idle_timeout
  smoke_run "T3: --always-on no + --idle-timeout 0 rejects"             test_t3_always_on_no_zero_idle_timeout_rejected
  smoke_run "T4: --always-on yes records expressed_intent"              test_t4_always_on_yes_records_intent
  smoke_run "T5: bare --idle-timeout omits expressed_intent"            test_t5_bare_idle_timeout_omits_intent
  smoke_run "T6: no-op --always-on no still records intent"             test_t6_noop_still_records_intent
  smoke_run "T7: agent add --always-on no co-flag + audit"              test_t7_agent_add_always_on_no
  smoke_log "passed"
}

main "$@"
