#!/usr/bin/env bash
# scripts/smoke/1398-a2a-inbound-stopped-target-force.sh
#
# Issue #1398 — A2A inbound enqueue must --force past the #1318 stopped-
# target guard. An inbound cross-bridge handoff is durable mail: a
# momentarily-stopped LOCAL target (no live tmux reader) is a NORMAL
# transient state, unlike an interactive operator send. The receiver
# (bridge-handoffd.py -> enqueue_via_bridge_task) therefore passes --force
# to bridge-task.sh create so the message lands in the queue for when the
# agent restarts, rather than being rejected with a 422 under the #1318
# reader-liveness guard.
#
# This is the inverse of the a2a-cross-bridge smoke, which deliberately
# brings the 'reviewer' tmux session UP before enqueuing. Here we LEAVE IT
# DOWN and assert:
#   - valid signed inbound handoff to a STOPPED local target -> 200 ENQUEUED
#     (not 422) + visible in the local inbox (proves the real bridge-task.sh
#     create --force boundary ran past the #1318 guard).
#   - --force is the stopped-target liveness override ONLY; the auth/dedupe
#     gates upstream of the enqueue stay fully enforced even for a stopped
#     target:
#       * bad HMAC signature -> 401 (auth not weakened)
#       * same message_id + different body -> 409 (dedupe not weakened)

set -euo pipefail

SMOKE_NAME="1398-a2a-inbound-stopped-target-force"
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
# A tmux session name that is recorded in the roster but is INTENTIONALLY
# never started. bridge_agent_is_active "reviewer" must therefore return
# false, so the #1318 stopped-target guard fires unless the receiver passes
# --force. The unique suffix guarantees no pre-existing host session can
# accidentally satisfy the liveness check.
REVIEWER_SESSION_NAME="a2a-1398-stopped-$$-${RANDOM}"

# Reuse the canonical signing/sending helper from the cross-bridge smoke so
# this smoke exercises the real HMAC scheme + real envelope shape.
helper() {
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" "$@"
}

pick_free_port() {
  helper free-port
}

base_url() {
  printf 'http://127.0.0.1:%s' "$A2A_PORT"
}

# Roster with a 'reviewer' agent whose tmux session is NAMED but never
# created — i.e. the agent is stopped from bridge_agent_is_active's POV.
write_a2a_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/reviewer"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="reviewer"
bridge_add_agent_id_if_missing "reviewer"
BRIDGE_AGENT_DESC["reviewer"]="A2A #1398 stopped-target smoke reviewer"
BRIDGE_AGENT_ENGINE["reviewer"]="shell"
BRIDGE_AGENT_SESSION["reviewer"]="$REVIEWER_SESSION_NAME"
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

start_receiver() {
  A2A_PORT="$(pick_free_port)"
  write_a2a_config "$A2A_PORT"
  BRIDGE_A2A_ALLOW_TEST_BIND=1 \
    python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" serve \
      --config "$BRIDGE_HOME/handoff.local.json" \
      >"$SMOKE_TMP_ROOT/handoffd.log" 2>&1 &
  HANDOFFD_PID=$!

  local waited=0
  while (( waited < 50 )); do
    if helper wait-port "$A2A_PORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  smoke_fail "receiver did not start; log: $(cat "$SMOKE_TMP_ROOT/handoffd.log")"
}

# Precondition guard: the target really IS stopped. If a stray tmux session
# named like our reviewer existed, the #1318 guard would not fire and the
# test would pass for the wrong reason. Assert bridge_agent_is_active is
# false before exercising the enqueue.
assert_target_stopped() {
  if tmux has-session -t "=${REVIEWER_SESSION_NAME}" 2>/dev/null; then
    smoke_fail "precondition: reviewer session '$REVIEWER_SESSION_NAME' unexpectedly exists"
  fi
}

# THE core assertion: a valid signed inbound handoff to a STOPPED local
# target must ENQUEUE (200), not 422 under the #1318 guard, and must be
# visible in the local inbox (so it went through the real bridge-task.sh
# create boundary with --force).
inbound_to_stopped_target_enqueues() {
  local out task_id inbox_out
  out="$(helper ok "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=200" \
    "inbound handoff to STOPPED local target -> 200 ENQUEUED (not 422 under #1318)"
  smoke_assert_not_contains "$out" "STATUS=422" \
    "stopped-target inbound is NOT rejected with 422"
  task_id="$(printf '%s\n' "$out" | sed -n 's/.*"task_id"[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  smoke_assert_match "$task_id" '^[0-9]+$' "stopped-target enqueue returned a local task id"

  inbox_out="$("$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer)"
  smoke_assert_contains "$inbox_out" "a2a smoke ok" \
    "durably-queued handoff visible in stopped agent's inbox (waits for restart)"
}

# --force bypasses ONLY the stopped-target liveness guard. Auth must still be
# enforced for a stopped target: a forged HMAC signature is rejected 401, it
# does NOT get a free pass into the queue just because the target is stopped.
auth_still_enforced_when_stopped() {
  local out
  out="$(helper auth-fail "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=401" \
    "bad HMAC to stopped target -> 401 (auth NOT weakened by --force)"
  smoke_assert_not_contains "$out" "STATUS=200" \
    "forged signature does NOT enqueue even against a stopped target"
}

# Dedupe must still be enforced for a stopped target: a message_id reuse with
# a DIFFERENT body is a 409 hash-conflict, not a second silent enqueue.
dedupe_still_enforced_when_stopped() {
  local first second
  first="$(helper dup-same "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$first" "STATUS=200" \
    "first dup-same inbound to stopped target -> 200 enqueued"

  second="$(helper dup-conflict "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$second" "STATUS=409" \
    "message_id reuse w/ different body to stopped target -> 409 (dedupe NOT weakened)"
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd tmux
  smoke_setup_bridge_home "1398-a2a-inbound-stopped-target-force"
  write_a2a_roster

  smoke_run "precondition: target reviewer is stopped (no tmux session)" assert_target_stopped
  smoke_run "start loopback receiver (test-bind)" start_receiver
  smoke_run "inbound to STOPPED local target -> 200 enqueued (not 422)" inbound_to_stopped_target_enqueues
  smoke_run "auth still enforced for stopped target (bad HMAC -> 401)" auth_still_enforced_when_stopped
  smoke_run "dedupe still enforced for stopped target (conflict -> 409)" dedupe_still_enforced_when_stopped

  smoke_log "passed"
}

main "$@"
