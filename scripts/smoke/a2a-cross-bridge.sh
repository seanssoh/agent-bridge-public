#!/usr/bin/env bash
# scripts/smoke/a2a-cross-bridge.sh — A2A cross-bridge handoff smoke (#1032).
#
# Exercises the receiver daemon + sender delivery runner end-to-end against
# a loopback-bound receiver (BRIDGE_A2A_ALLOW_TEST_BIND=1). Covers:
#   - tailnet-bind fail-closed (wildcard refused at startup)
#   - HMAC auth failure -> 401
#   - allowlist failure -> 403
#   - clock-skew rejection -> 401
#   - body-size cap -> 413
#   - successful enqueue -> 200 + local inbox visibility (via bridge-task.sh)
#   - duplicate same-hash -> idempotent 200 with original task id
#   - duplicate hash-conflict -> 409
#   - receiver-down delivery -> outbox retry (not dead)

set -euo pipefail

SMOKE_NAME="a2a-cross-bridge"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HANDOFFD_PID=""

cleanup() {
  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

A2A_PORT=""
A2A_SECRET="smoke-shared-secret-do-not-use-in-prod-0123456789"

pick_free_port() {
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" free-port
}

write_a2a_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/reviewer"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="reviewer"
bridge_add_agent_id_if_missing "reviewer"
BRIDGE_AGENT_DESC["reviewer"]="A2A smoke reviewer"
BRIDGE_AGENT_ENGINE["reviewer"]="shell"
BRIDGE_AGENT_SESSION["reviewer"]="a2a-smoke-session"
BRIDGE_AGENT_WORKDIR["reviewer"]="$workdir"
BRIDGE_AGENT_LAUNCH_CMD["reviewer"]="bash -lc 'echo reviewer'"
BRIDGE_AGENT_LOOP["reviewer"]=0
BRIDGE_AGENT_CONTINUE["reviewer"]=0
EOF
}

write_a2a_config() {
  local port="$1"
  cat >"$BRIDGE_HOME/handoff.local.json" <<EOF
{
  "bridge_id": "bridge-b",
  "listen": { "address": "127.0.0.1", "port": ${port}, "enqueue_path": "/enqueue" },
  "timestamp_skew_seconds": 300,
  "peers": [
    {
      "id": "bridge-a",
      "address": "127.0.0.1",
      "port": ${port},
      "secret": "${A2A_SECRET}",
      "inbound_allowlist": ["reviewer"],
      "caps": { "max_body_bytes": 262144, "max_title_bytes": 1024 }
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff.local.json"
}

write_wildcard_config() {
  cat >"$BRIDGE_HOME/handoff-wildcard.json" <<'EOF'
{
  "bridge_id": "bridge-b",
  "listen": { "address": "0.0.0.0", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-wildcard.json"
}

# --- scenario: receiver refuses a wildcard bind (fail-closed) ---
fail_closed_wildcard() {
  write_wildcard_config
  local out rc=0
  out="$(python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" preflight \
    --config "$BRIDGE_HOME/handoff-wildcard.json" 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" "wildcard bind preflight exits non-zero"
  smoke_assert_contains "$out" "bind_wildcard" "wildcard bind reports bind_wildcard"
}

# BLOCKING #2 regression guard: with the `tailscale` CLI unavailable the
# receiver must FAIL CLOSED — it must not fall back to a CIDR-shape guess
# and approve a tailnet-shaped address. `BRIDGE_A2A_TAILSCALE_CLI` points
# CLI discovery at a path that does not exist (the genuine "unavailable"
# condition — deterministic regardless of whether the test host happens
# to have `tailscale` on PATH or in a standard install location), then
# preflights a config with a tailnet-shaped (100.64.0.0/10) bind address
# that is NOT a real local interface.
fail_closed_without_tailscale_cli() {
  cat >"$BRIDGE_HOME/handoff-cgnat.json" <<'EOF'
{
  "bridge_id": "bridge-b",
  "listen": { "address": "100.64.0.10", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-cgnat.json"

  local out rc=0
  out="$(BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" \
    python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" \
    preflight --config "$BRIDGE_HOME/handoff-cgnat.json" 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" "preflight fails closed when tailscale CLI absent"
  smoke_assert_contains "$out" "tailscale_unavailable" \
    "absent tailscale CLI reports tailscale_unavailable (no CIDR-shape fallback)"
  smoke_assert_not_contains "$out" "preflight] OK" \
    "tailnet-shaped CGNAT address NOT approved without a real local match"
}

start_receiver() {
  A2A_PORT="$(pick_free_port)"
  write_a2a_config "$A2A_PORT"
  BRIDGE_A2A_ALLOW_TEST_BIND=1 \
    python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" serve \
      --config "$BRIDGE_HOME/handoff.local.json" \
      >"$SMOKE_TMP_ROOT/handoffd.log" 2>&1 &
  HANDOFFD_PID=$!

  # Wait for the listener.
  local waited=0
  while (( waited < 50 )); do
    if python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  smoke_fail "receiver did not start; log: $(cat "$SMOKE_TMP_ROOT/handoffd.log")"
}

helper() {
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" "$@"
}

base_url() {
  printf 'http://127.0.0.1:%s' "$A2A_PORT"
}

auth_fail() {
  local out
  out="$(helper auth-fail "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=401" "bad HMAC signature -> 401"
}

allowlist_fail() {
  local out
  out="$(helper allowlist-fail "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=403" "non-allowlisted target -> 403"
  smoke_assert_contains "$out" "allowlist" "403 body mentions allowlist"
}

skew_reject() {
  local out
  out="$(helper skew "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=401" "stale timestamp -> 401"
}

oversize_cap() {
  local out
  out="$(helper oversize "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=413" "oversized body -> 413"
}

successful_enqueue() {
  local out task_id inbox_out
  out="$(helper ok "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=200" "valid signed handoff -> 200"
  task_id="$(printf '%s\n' "$out" | sed -n 's/.*"task_id"[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  smoke_assert_match "$task_id" '^[0-9]+$' "enqueue returned a local task id"

  # The handoff must be visible in the local agent's inbox — proves the
  # receiver routed through the real bridge-task.sh create boundary.
  inbox_out="$("$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer)"
  smoke_assert_contains "$inbox_out" "a2a smoke ok" "enqueued handoff visible in local inbox"
}

duplicate_same_hash() {
  local first second first_task second_task
  first="$(helper dup-same "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$first" "STATUS=200" "first dup-same POST -> 200"
  first_task="$(printf '%s\n' "$first" | sed -n 's/.*"task_id"[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"

  # Identical message_id + identical body -> idempotent, same task id.
  second="$(helper dup-same "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$second" "STATUS=200" "duplicate same-hash -> idempotent 200"
  smoke_assert_contains "$second" '"duplicate": true' "duplicate flagged in response"
  second_task="$(printf '%s\n' "$second" | sed -n 's/.*"task_id"[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  smoke_assert_eq "$first_task" "$second_task" "duplicate returns the original task id"
}

duplicate_hash_conflict() {
  # Same message_id as dup-same, DIFFERENT body -> 409 security event.
  local out
  out="$(helper dup-conflict "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=409" "message-id reuse w/ different body -> 409"
}

# Write a sender-side A2A config: bridge_id=bridge-a, one peer 'bridge-b'
# at 127.0.0.1:<port>. The receiver's own config (write_a2a_config) has
# bridge_id=bridge-b and an inbound peer 'bridge-a' allowlisting reviewer,
# so the reciprocal pair lines up: the sender signs + sends X-AGB-Peer as
# its OWN id 'bridge-a', which is exactly what the receiver looks up.
write_sender_config() {
  local port="$1"
  cat >"$BRIDGE_HOME/handoff-sender.json" <<EOF
{
  "bridge_id": "bridge-a",
  "listen": { "address": "127.0.0.1", "port": ${port} },
  "peers": [
    {
      "id": "bridge-b",
      "address": "127.0.0.1",
      "port": ${port},
      "secret": "${A2A_SECRET}",
      "inbound_allowlist": ["reviewer"]
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-sender.json"
}

sender_outbox() {
  BRIDGE_A2A_CONFIG="$BRIDGE_HOME/handoff-sender.json" \
    python3 "$SMOKE_REPO_ROOT/bridge-a2a.py" "$@"
}

# BLOCKING #1 regression guard: drive the REAL bridge-a2a.py send +
# deliver path against the LIVE receiver and assert a 200 ACK + a local
# enqueue. The earlier 11-scenario smoke posted the success case via the
# helper (peer_id=bridge-a) directly and only ran send+deliver against a
# DEAD receiver, so it missed the X-AGB-Peer identity mismatch entirely.
live_send_deliver() {
  write_sender_config "$A2A_PORT"

  sender_outbox send --peer bridge-b --to reviewer --from senderX \
    --title "live send deliver" --body "real send+deliver body" >/dev/null

  local before
  before="$(sender_outbox outbox list)"
  smoke_assert_contains "$before" "pending" "real send created a pending outbox row"

  sender_outbox deliver --timeout 5 >/dev/null 2>&1 || true

  local after
  after="$(sender_outbox outbox list)"
  smoke_assert_contains "$after" "acked" "real deliver against live receiver -> acked"
  smoke_assert_not_contains "$after" "dead" "real send+deliver did not dead-letter"

  # The acked outbox row must carry the remote task id, and that task
  # must be visible in the receiver's local inbox.
  local inbox_out
  inbox_out="$("$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer)"
  smoke_assert_contains "$inbox_out" "live send deliver" \
    "send+deliver handoff visible in receiver local inbox"
}

receiver_down_retry() {
  # Configure a sender outbox pointing at a dead port; deliver once and
  # assert the entry is retried (status=retry), not dead-lettered.
  local dead_port
  dead_port="$(pick_free_port)"
  write_sender_config "$dead_port"

  sender_outbox send --peer bridge-b --to reviewer --from senderX \
    --title "retry probe" --body "will not connect" >/dev/null

  local outbox_before
  outbox_before="$(sender_outbox outbox list)"
  smoke_assert_contains "$outbox_before" "pending" "send created a pending outbox entry"

  sender_outbox deliver --timeout 3 >/dev/null 2>&1 || true

  local outbox_after
  outbox_after="$(sender_outbox outbox list)"
  smoke_assert_contains "$outbox_after" "retry" "unreachable receiver -> outbox entry retried"
  smoke_assert_not_contains "$outbox_after" "dead" "transient failure not dead-lettered on first attempt"
}

# BLOCKING #3 regression guard: a row left in status='sending' with an
# expired lease (its runner crashed mid-attempt) must be reclaimed by the
# next deliver tick, not skipped forever.
stale_lease_reclaim() {
  write_sender_config "$A2A_PORT"

  sender_outbox send --peer bridge-b --to reviewer --from senderX \
    --title "stale lease probe" --body "crashed-runner body" >/dev/null

  # Force the freshly-queued row into a crashed-runner state: status
  # 'sending' with a lease that already expired.
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wedge-sending \
    "$BRIDGE_STATE_DIR/handoff/outbox.db"
  local wedged
  wedged="$(sender_outbox outbox list)"
  smoke_assert_contains "$wedged" "sending" "row forced into stale 'sending' state"

  # A deliver tick must reclaim it and (against the live receiver) ack it.
  sender_outbox deliver --timeout 5 >/dev/null 2>&1 || true
  local after
  after="$(sender_outbox outbox list)"
  smoke_assert_not_contains "$after" "sending" "stale 'sending' row no longer wedged"
  smoke_assert_contains "$after" "acked" "reclaimed row delivered on the next tick"
}

dry_run_no_outbox_write() {
  # --dry-run must not persist anything to the outbox.
  local out before after
  before="$(sender_outbox outbox list | grep -c . || true)"
  out="$(sender_outbox send --peer bridge-b --to reviewer \
    --title "dry one" --body "x" --dry-run)"
  smoke_assert_contains "$out" '"dry_run": true' "dry-run reports dry_run flag"
  after="$(sender_outbox outbox list | grep -c . || true)"
  smoke_assert_eq "$before" "$after" "dry-run did not add an outbox row"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "a2a-cross-bridge"
  write_a2a_roster

  smoke_run "receiver fail-closed on wildcard bind" fail_closed_wildcard
  smoke_run "receiver fail-closed when tailscale CLI absent" fail_closed_without_tailscale_cli
  smoke_run "start loopback receiver (test-bind)" start_receiver
  smoke_run "HMAC auth failure -> 401" auth_fail
  smoke_run "allowlist failure -> 403" allowlist_fail
  smoke_run "clock-skew rejection -> 401" skew_reject
  smoke_run "body-size cap -> 413" oversize_cap
  smoke_run "successful enqueue -> local inbox visibility" successful_enqueue
  smoke_run "duplicate same-hash -> idempotent" duplicate_same_hash
  smoke_run "duplicate hash-conflict -> 409" duplicate_hash_conflict
  smoke_run "real send+deliver -> live receiver 200 + enqueue" live_send_deliver
  smoke_run "receiver-down delivery -> outbox retry" receiver_down_retry
  smoke_run "stale 'sending' lease reclaimed on next tick" stale_lease_reclaim
  smoke_run "send --dry-run writes no outbox row" dry_run_no_outbox_write

  smoke_log "passed"
}

main "$@"
