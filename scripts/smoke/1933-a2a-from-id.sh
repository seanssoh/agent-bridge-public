#!/usr/bin/env bash
# scripts/smoke/1933-a2a-from-id.sh — `agb a2a send` sender-id resolution (#1933).
#
# Issue #1933: cmd_send used to resolve the sender ("from") identity with a
# final fallback to the OS username:
#
#     sender_agent = args.from_agent or BRIDGE_AGENT_ID or os.environ["USER"]
#
# When --from is omitted AND BRIDGE_AGENT_ID is unset (subagents, cron-
# dispatched children, non-managed background bash), the outgoing envelope
# carried a `from` id that is NOT a valid agent id (the OS login name). A peer
# reply echoing it routes to a target the SENDER's OWN receiver rejects with
# reject_allowlist — a self-inflicted 403 that masquerades as a pairing fault.
#
# The fix drops the USER fallback: resolve --from then BRIDGE_AGENT_ID only; if
# neither yields a non-empty id, fail fast with an actionable error instead of
# emitting an unroutable OS-username from-id.
#
# This smoke is hermetic — it drives the REAL bridge-a2a.py cmd_send path but
# never binds the network: the fail-fast case exits before any outbox write,
# and the positive case enqueues to a dead-port peer (delivery is a separate
# tick) so we can read the staged envelope and assert the stamped sender id.

set -euo pipefail

SMOKE_NAME="1933-a2a-from-id"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# A sentinel OS username we plant into the environment. If the dropped USER
# fallback ever returns, this value would leak into the wire `from` and the
# no-from send would (wrongly) succeed — the mutation guard turns on that.
SENTINEL_USER="osloginname-not-an-agent-$$"
# A legitimate (neutral fixture) agent id used on the valid-sender paths.
REAL_AGENT="sender-agent"

write_sender_config() {
  # bridge_id=bridge-a, one peer 'bridge-b' at a dead loopback port. The send
  # only stages + enqueues; it does NOT connect, so the port never has to be
  # live (delivery is a separate `a2a deliver` tick we never run here).
  cat >"$BRIDGE_HOME/handoff-sender.json" <<EOF
{
  "bridge_id": "bridge-a",
  "listen": { "address": "127.0.0.1", "port": 1 },
  "peers": [
    {
      "id": "bridge-b",
      "address": "127.0.0.1",
      "port": 1,
      "secret": "smoke-shared-secret-do-not-use-in-prod-0123456789",
      "inbound_allowlist": ["reviewer"]
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-sender.json"
}

# Run cmd_send with BRIDGE_AGENT_ID forced UNSET and USER pinned to the
# sentinel, so the only way a sender id appears is a legitimate --from / a
# caller-exported BRIDGE_AGENT_ID — never the OS username.
send_no_managed_env() {
  env -u BRIDGE_AGENT_ID USER="$SENTINEL_USER" \
    BRIDGE_A2A_CONFIG="$BRIDGE_HOME/handoff-sender.json" \
    python3 "$SMOKE_REPO_ROOT/bridge-a2a.py" send "$@"
}

# Resolve the outgoing/ staging dir through the shared module so this smoke
# does not hardcode the handoff layout.
outgoing_dir() {
  BRIDGE_A2A_CONFIG="$BRIDGE_HOME/handoff-sender.json" \
    PYTHONPATH="$SMOKE_REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -c "import bridge_a2a_common as a2a; print(a2a.outgoing_dir())"
}

# (1) no --from, no BRIDGE_AGENT_ID -> fail fast, no OS-username from-id.
fail_fast_without_sender() {
  local out rc=0
  out="$(send_no_managed_env --peer bridge-b --to reviewer \
    --title "no sender" --body "x" --dry-run 2>&1)" || rc=$?

  smoke_assert_match "$rc" '^[1-9]' \
    "send without --from/BRIDGE_AGENT_ID exits non-zero (fail fast)"
  smoke_assert_contains "$out" "--from" \
    "error names --from as the remedy"
  smoke_assert_contains "$out" "BRIDGE_AGENT_ID" \
    "error names BRIDGE_AGENT_ID as the remedy"
  # The whole point of #1933: the OS login name must never become the from-id.
  smoke_assert_not_contains "$out" "$SENTINEL_USER" \
    "OS username never emitted as the sender id"
  smoke_assert_not_contains "$out" '"dry_run": true' \
    "no envelope produced when the sender id cannot be resolved"
}

# (2) empty-string --from (the --from \"\$UNSET\" trap) is treated as unset.
fail_fast_empty_from() {
  local out rc=0
  out="$(send_no_managed_env --peer bridge-b --to reviewer --from "" \
    --title "empty from" --body "x" --dry-run 2>&1)" || rc=$?

  smoke_assert_match "$rc" '^[1-9]' \
    "send with --from '' exits non-zero (empty string is not a sender)"
  smoke_assert_not_contains "$out" "$SENTINEL_USER" \
    "empty --from does not degrade to the OS username"
}

# (3) explicit --from resolves and is stamped into the staged envelope.
explicit_from_resolves() {
  local rc=0
  send_no_managed_env --peer bridge-b --to reviewer --from "$REAL_AGENT" \
    --title "explicit from" --body "real body" >/dev/null 2>&1 || rc=$?
  smoke_assert_eq 0 "$rc" "send with explicit --from succeeds (exit 0)"

  local odir env_json sender reply
  odir="$(outgoing_dir)"
  env_json="$(cat "$odir"/*.json)"
  sender="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['sender']['agent'])" "$env_json")"
  reply="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['reply_to']['agent'])" "$env_json")"
  smoke_assert_eq "$REAL_AGENT" "$sender" "envelope sender.agent is the --from id"
  smoke_assert_eq "$REAL_AGENT" "$reply" "envelope reply_to.agent is the --from id"
  smoke_assert_not_contains "$env_json" "$SENTINEL_USER" \
    "OS username does not appear anywhere in the staged envelope"
}

# (4) BRIDGE_AGENT_ID (managed-session export) resolves with no --from.
env_agent_id_resolves() {
  local out rc=0
  out="$(env USER="$SENTINEL_USER" BRIDGE_AGENT_ID="$REAL_AGENT" \
    BRIDGE_A2A_CONFIG="$BRIDGE_HOME/handoff-sender.json" \
    python3 "$SMOKE_REPO_ROOT/bridge-a2a.py" send \
    --peer bridge-b --to reviewer \
    --title "env from" --body "x" --dry-run 2>&1)" || rc=$?
  smoke_assert_eq 0 "$rc" "send with BRIDGE_AGENT_ID set + no --from succeeds"
  smoke_assert_contains "$out" '"dry_run": true' "dry-run envelope produced"
  smoke_assert_not_contains "$out" "$SENTINEL_USER" \
    "BRIDGE_AGENT_ID path never falls back to the OS username"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  write_sender_config

  smoke_run "no --from/BRIDGE_AGENT_ID -> fail fast, no OS-username id" fail_fast_without_sender
  smoke_run "empty --from '' -> fail fast (not OS username)" fail_fast_empty_from
  smoke_run "explicit --from stamped into envelope" explicit_from_resolves
  smoke_run "BRIDGE_AGENT_ID resolves with no --from" env_agent_id_resolves

  smoke_log "passed"
}

main "$@"
