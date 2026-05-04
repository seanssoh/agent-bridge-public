#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="queue"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  if [[ -n "${QUEUE_SOCKET_SERVER_PID:-}" ]]; then
    kill "$QUEUE_SOCKET_SERVER_PID" >/dev/null 2>&1 || true
    wait "$QUEUE_SOCKET_SERVER_PID" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

queue_lifecycle() {
  local body_file create_out task_id body_path show_out events_json event_types

  body_file="$SMOKE_TMP_ROOT/request-body.md"
  printf 'queue smoke body\n' >"$body_file"

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null

  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a \
      --from requester \
      --priority high \
      --title "queue smoke task" \
      --body-file "$body_file" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  body_path="$(smoke_shell_field TASK_BODY_PATH "$create_out")"

  smoke_assert_match "$task_id" '^[0-9]+$' "queue create returned task id"
  smoke_assert_contains "$body_path" "$BRIDGE_STATE_DIR/queue/bodies/" "ephemeral body-file stabilization"
  smoke_assert_file_exists "$body_path" "stabilized queue body"
  smoke_assert_eq "queue smoke body" "$(tr -d '\n' <"$body_path")" "stabilized body content"

  show_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_STATUS=queued" "created task status"

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" claim "$task_id" --agent worker-a --lease-seconds 60 >/dev/null
  show_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_STATUS=claimed" "claimed task status"
  smoke_assert_contains "$show_out" "TASK_CLAIMED_BY=worker-a" "claimed task owner"

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" done "$task_id" --agent worker-a --note "queue smoke complete" >/dev/null
  show_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_STATUS=done" "completed task status"

  events_json="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" events --format json)"
  event_types="$(python3 - "$events_json" "$task_id" <<'PY'
import json
import sys

events = json.loads(sys.argv[1])
task_id = int(sys.argv[2])
print(",".join(event["event_type"] for event in events if event["task_id"] == task_id))
PY
)"
  smoke_assert_eq "created,claimed,done" "$event_types" "queue lifecycle event sequence"
}

queue_daemon_step_contract() {
  local create_out task_id now_ts activity_ts snapshot nudge_out same_out new_out second_id

  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to daemon-worker \
      --from requester \
      --title "daemon nudge smoke" \
      --body "daemon nudge body" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  now_ts="$(date +%s)"
  activity_ts="$((now_ts - 300))"
  snapshot="$SMOKE_TMP_ROOT/agent-summary.tsv"
  cat >"$snapshot" <<EOF
agent	queued	claimed	blocked	active	idle	last_seen	last_nudge	session	engine	workdir	session_activity_ts
daemon-worker	1	0	0	1	300	$now_ts	0	daemon-session	claude	$SMOKE_TMP_ROOT/daemon-worker	$activity_ts
EOF

  nudge_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" daemon-step \
      --snapshot "$snapshot" \
      --idle-threshold 120 \
      --nudge-cooldown 900 \
      --format tsv
  )"
  smoke_assert_contains "$nudge_out" $'daemon-worker	daemon-session	1	0' "daemon-step nudge candidate"
  smoke_assert_contains "$nudge_out" "$task_id" "daemon-step nudge key"

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" note-nudge --agent daemon-worker --key "$task_id" >/dev/null
  same_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" daemon-step \
      --snapshot "$snapshot" \
      --idle-threshold 120 \
      --nudge-cooldown 900 \
      --format tsv
  )"
  smoke_assert_eq "" "$same_out" "daemon-step suppresses duplicate nudge during cooldown"

  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to daemon-worker \
      --from requester \
      --title "daemon nudge smoke second" \
      --body "second body" \
      --format shell
  )"
  second_id="$(smoke_shell_field TASK_ID "$create_out")"
  new_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" daemon-step \
      --snapshot "$snapshot" \
      --idle-threshold 120 \
      --nudge-cooldown 900 \
      --format tsv
  )"
  smoke_assert_contains "$new_out" "$task_id,$second_id" "daemon-step retries when a new queued task arrives"
}

queue_gateway_socket_env() {
  export BRIDGE_GATEWAY_PROXY=1
  export BRIDGE_AGENT_ID=worker-a
  export BRIDGE_GATEWAY_TRANSPORT=socket
  export BRIDGE_QUEUE_GATEWAY_PEERS="$(id -u):worker-a"
  export BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT="$SMOKE_TMP_ROOT/queue-gateway-runtime"
  export BRIDGE_TMPFILES_DIR="$SMOKE_TMP_ROOT/tmpfiles.d"
  export BRIDGE_TMPFILES_DRIVER=shim
}

queue_gateway_socket_path() {
  local bridge_id
  bridge_id="$(python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" print-runtime-id --bridge-home "$BRIDGE_HOME")"
  printf '%s/%s/queue-gateway.sock' "$BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT" "$bridge_id"
}

queue_gateway_stop_socket_server() {
  if [[ -n "${QUEUE_SOCKET_SERVER_PID:-}" ]]; then
    kill "$QUEUE_SOCKET_SERVER_PID" >/dev/null 2>&1 || true
    wait "$QUEUE_SOCKET_SERVER_PID" >/dev/null 2>&1 || true
    QUEUE_SOCKET_SERVER_PID=""
  fi
}

queue_gateway_start_socket_server() {
  local socket_path="$1"
  local log_file="$2"
  local i

  BRIDGE_QUEUE_GATEWAY_SERVER=1 python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" socket-server \
    --bridge-home "$BRIDGE_HOME" \
    --queue-script "$SMOKE_REPO_ROOT/bridge-queue.py" >"$log_file" 2>&1 &
  QUEUE_SOCKET_SERVER_PID="$!"

  for ((i = 0; i < 50; i++)); do
    if [[ -S "$socket_path" ]] && kill -0 "$QUEUE_SOCKET_SERVER_PID" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  smoke_fail "queue gateway socket server did not start; log=$(cat "$log_file" 2>/dev/null || true)"
}

queue_gateway_runtime_id_contract() {
  local actual_home link_home bash_id python_id missing_home bash_missing python_missing

  actual_home="$SMOKE_TMP_ROOT/runtime-id-home"
  link_home="$SMOKE_TMP_ROOT/runtime-id-link"
  missing_home="$SMOKE_TMP_ROOT/runtime-id-missing"
  mkdir -p "$actual_home"
  ln -s "$actual_home" "$link_home"

  bash_id="$(bash -c 'source "$1/bridge-lib.sh"; bridge_runtime_id "$2"' bash "$SMOKE_REPO_ROOT" "$link_home")"
  python_id="$(python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" print-runtime-id --bridge-home "$link_home")"
  smoke_assert_eq "$python_id" "$bash_id" "bash/python runtime id parity for symlinked home"

  bash_missing="$(bash -c 'source "$1/bridge-lib.sh"; bridge_runtime_id "$2"' bash "$SMOKE_REPO_ROOT" "$missing_home")"
  python_missing="$(python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" print-runtime-id --bridge-home "$missing_home")"
  smoke_assert_eq "$python_missing" "$bash_missing" "bash/python runtime id parity for missing home"
}

queue_gateway_socket_contract() {
  local socket_path server_log create_out task_id show_out assigned_id denied_out denied_rc secret log_body
  local other_out other_id instance_dir oversize_out oversize_rc
  local socket_mode

  queue_gateway_socket_env
  BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" ensure-runtime --bridge-home "$BRIDGE_HOME" --strict >/dev/null
  socket_path="$(queue_gateway_socket_path)"
  server_log="$SMOKE_TMP_ROOT/queue-gateway-socket.log"
  queue_gateway_start_socket_server "$socket_path" "$server_log"
  socket_mode="$(stat -c '%a' "$socket_path")"
  case "$socket_mode" in
    *[1-7])
      smoke_fail "queue gateway socket must not be world-writable/readable; mode=$socket_mode"
      ;;
  esac

  secret="QUEUE_SOCKET_SMOKE_SECRET_DO_NOT_LOG"
  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a \
      --from forged-controller \
      --title "socket gateway create" \
      --body "$secret" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  show_out="$(BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_CREATED_BY=worker-a" "socket gateway forces create actor to peer"

  create_out="$(
    BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a \
      --from requester \
      --title "socket gateway assigned task" \
      --body "assigned body" \
      --format shell
  )"
  assigned_id="$(smoke_shell_field TASK_ID "$create_out")"
  show_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" inbox --agent forged-agent)"
  smoke_assert_contains "$show_out" "$assigned_id" "socket gateway forces inbox agent to peer"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" claim "$assigned_id" --agent forged-agent --lease-seconds 60 >/dev/null
  show_out="$(BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$assigned_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_CLAIMED_BY=worker-a" "socket gateway forces claim agent to peer"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" done "$assigned_id" --agent forged-agent --note "socket done" >/dev/null
  show_out="$(BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$assigned_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_STATUS=done" "socket gateway allows peer done"

  set +e
  denied_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" events --format json 2>&1)"
  denied_rc=$?
  set -e
  [[ "$denied_rc" -ne 0 ]] || smoke_fail "socket gateway events should be denied"
  smoke_assert_contains "$denied_out" "queue gateway denied" "socket gateway denies daemon-only events"

  other_out="$(
    BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to other-agent \
      --from requester \
      --title "socket gateway other task" \
      --body "other body" \
      --format shell
  )"
  other_id="$(smoke_shell_field TASK_ID "$other_out")"
  set +e
  denied_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" done "$other_id" --agent forged-agent --note "not owner" 2>&1)"
  denied_rc=$?
  set -e
  [[ "$denied_rc" -ne 0 ]] || smoke_fail "socket gateway done should be denied for non-owner"
  smoke_assert_contains "$denied_out" "queue gateway denied" "socket gateway denies done for non-owner"

  set +e
  oversize_out="$(python3 - "$socket_path" <<'PY' 2>&1
import json
import socket
import sys

sock_type = getattr(socket, "SOCK_SEQPACKET", None)
if sock_type is None:
    raise SystemExit(0)
payload = {"id": "oversize", "argv": ["inbox", "--agent", "forged"], "padding": "x" * (2 * 1024 * 1024 + 16)}
with socket.socket(socket.AF_UNIX, sock_type) as sock:
    sock.settimeout(5)
    sock.connect(sys.argv[1])
    try:
        sock.sendall(json.dumps(payload).encode("utf-8"))
        data = sock.recv(4096)
        sys.stdout.write(data.decode("utf-8", "replace"))
    except OSError as exc:
        sys.stdout.write(type(exc).__name__)
PY
)"
  oversize_rc=$?
  set -e
  [[ "$oversize_rc" -eq 0 ]] || smoke_fail "oversize socket probe crashed: $oversize_out"
  smoke_assert_not_contains "$(cat "$server_log")" "${secret}" "socket gateway log redacts request bodies"

  instance_dir="$(dirname "$socket_path")"
  queue_gateway_stop_socket_server
  [[ ! -S "$socket_path" ]] || smoke_fail "socket file should be removed on listener stop"
  [[ -d "$instance_dir" ]] || smoke_fail "runtime instance dir should survive listener restart"
  queue_gateway_start_socket_server "$socket_path" "$server_log"
  [[ -S "$socket_path" ]] || smoke_fail "socket should exist after listener restart"
  socket_mode="$(stat -c '%a' "$socket_path")"
  case "$socket_mode" in
    *[1-7])
      smoke_fail "queue gateway socket restart must not be world-writable/readable; mode=$socket_mode"
      ;;
  esac
  log_body="$(cat "$server_log")"
  smoke_assert_not_contains "$log_body" "${secret}" "socket gateway log stays payload-free after restart"
}

queue_gateway_socket_acl_contract() {
  local socket_path server_log nobody_uid acl_body socket_mode

  if ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
    smoke_log "skip: queue gateway socket peer ACL contract requires setfacl/getfacl"
    return 0
  fi
  if ! nobody_uid="$(id -u nobody 2>/dev/null)"; then
    smoke_log "skip: queue gateway socket peer ACL contract requires nobody user"
    return 0
  fi

  queue_gateway_stop_socket_server
  queue_gateway_socket_env
  export BRIDGE_QUEUE_GATEWAY_PEERS="$(id -u):worker-a,${nobody_uid}:worker-b"
  BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" ensure-runtime --bridge-home "$BRIDGE_HOME" --strict >/dev/null
  socket_path="$(queue_gateway_socket_path)"
  server_log="$SMOKE_TMP_ROOT/queue-gateway-socket-acl.log"
  queue_gateway_start_socket_server "$socket_path" "$server_log"

  socket_mode="$(stat -c '%a' "$socket_path")"
  case "$socket_mode" in
    *[1-7])
      smoke_fail "queue gateway ACL socket must not be world-writable/readable; mode=$socket_mode"
      ;;
  esac
  acl_body="$(getfacl -cp "$socket_path")"
  smoke_assert_contains "$acl_body" "user:nobody:rw-" "socket ACL grants known non-controller peer UID"
  smoke_assert_contains "$acl_body" "other::---" "socket ACL denies unknown users at filesystem layer"

  queue_gateway_stop_socket_server
}

queue_gateway_runtime_repair_contract() {
  local socket_path instance_dir

  queue_gateway_stop_socket_server
  queue_gateway_socket_env
  python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" ensure-runtime --bridge-home "$BRIDGE_HOME" --strict >/dev/null
  socket_path="$(queue_gateway_socket_path)"
  instance_dir="$(dirname "$socket_path")"
  chmod 0700 "$instance_dir"
  if python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" verify-runtime --bridge-home "$BRIDGE_HOME" >/dev/null 2>&1; then
    smoke_fail "verify-runtime should fail after wrong instance mode"
  fi
  python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" ensure-runtime --bridge-home "$BRIDGE_HOME" --strict >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" verify-runtime --bridge-home "$BRIDGE_HOME" >/dev/null
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -b "$instance_dir" >/dev/null 2>&1 || true
    python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" verify-runtime --bridge-home "$BRIDGE_HOME" >/dev/null
  fi
}

# r2 finding 8a: option-before-task-id smuggling. The earlier _task_id()
# walked the argv looking for the first non-option token, which let the
# value of `--note 60` be misread as the positional task id while
# bridge-queue.py executed against a later positional. The strict
# walker (_extract_positional_task_id) skips known value-bearing flags
# per subcommand. This smoke asserts the gateway authorizes against the
# *real* positional task id, not the smuggled value.
queue_gateway_argv_rewriting_contract() {
  local socket_path server_log assigned_id other_id denied_out denied_rc show_out

  queue_gateway_stop_socket_server
  queue_gateway_socket_env
  BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" ensure-runtime --bridge-home "$BRIDGE_HOME" --strict >/dev/null
  socket_path="$(queue_gateway_socket_path)"
  server_log="$SMOKE_TMP_ROOT/queue-gateway-argv.log"
  queue_gateway_start_socket_server "$socket_path" "$server_log"

  # Task A is assigned to worker-a (the peer). Task B is assigned to
  # other-agent (peer is NOT an owner). The proxy peer is worker-a
  # (BRIDGE_QUEUE_GATEWAY_PEERS maps the running uid to worker-a).
  assigned_id="$(
    BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a --from requester \
      --title "argv smuggling assigned" --body "owned" \
      --format shell | sed -n 's/^TASK_ID=//p' | tr -d "'"
  )"
  other_id="$(
    BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to other-agent --from requester \
      --title "argv smuggling unowned" --body "not owned" \
      --format shell | sed -n 's/^TASK_ID=//p' | tr -d "'"
  )"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" claim "$assigned_id" --agent forged --lease-seconds 60 >/dev/null

  # Smuggle attempt: `done --note <assigned_id> <other_id>` — under the
  # old walker the gateway would look at <assigned_id> for ownership
  # (peer owns it via claim/assigned) and ALLOW, while the inner
  # bridge-queue.py would actually `done` <other_id> (peer does NOT own
  # it). The strict walker must extract <other_id> as the positional
  # and reject because peer is not an owner of that task.
  set +e
  denied_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" done \
      --note "$assigned_id" "$other_id" --agent forged 2>&1
  )"
  denied_rc=$?
  set -e
  [[ "$denied_rc" -ne 0 ]] || smoke_fail "argv smuggling: gateway should refuse done with smuggled --note value"
  smoke_assert_contains "$denied_out" "queue gateway denied" "argv smuggling: gateway emits denial"

  # Confirm task <other_id> is still queued/claimed-untouched, NOT done.
  show_out="$(BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$other_id" --format shell)"
  smoke_assert_not_contains "$show_out" "TASK_STATUS=done" "argv smuggling: unowned task must not be marked done"

  queue_gateway_stop_socket_server
}

# r3 finding 2a: argparse abbreviation smuggling. Without
# allow_abbrev=False on the inner bridge-queue.py parsers, argparse
# silently expands `--note-f` → `--note-file` (a value-taking flag),
# which under the r2 walker would consume the would-be assigned id
# while the gateway authorized against the smuggled value as a bare
# positional. The r3 contract requires both halves: bridge-queue.py
# subparsers set allow_abbrev=False, AND the gateway walker rejects
# unknown long options up front. This smoke confirms the gateway
# refuses the abbreviation form, AND that the full `--note` flag still
# works.
queue_gateway_argv_abbrev_smuggling_contract() {
  local socket_path server_log assigned_id denied_out denied_rc accept_out accept_rc show_out

  queue_gateway_stop_socket_server
  queue_gateway_socket_env
  BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" ensure-runtime --bridge-home "$BRIDGE_HOME" --strict >/dev/null
  socket_path="$(queue_gateway_socket_path)"
  server_log="$SMOKE_TMP_ROOT/queue-gateway-abbrev.log"
  queue_gateway_start_socket_server "$socket_path" "$server_log"

  assigned_id="$(
    BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a --from requester \
      --title "abbrev smuggling assigned" --body "owned" \
      --format shell | sed -n 's/^TASK_ID=//p' | tr -d "'"
  )"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" claim "$assigned_id" --agent worker-a --lease-seconds 60 >/dev/null

  # Smuggle attempt: `done --note-f <assigned_id> <some_other_id> --agent forged`.
  # Under default-on argparse abbreviation, the inner parser would expand
  # `--note-f` → `--note-file`, swallowing <assigned_id> and operating on
  # <some_other_id>. The gateway walker (r3) does not know `--note-f`, so
  # it must reject as `unknown_option` BEFORE any DB lookup or argv
  # rewriting can occur.
  set +e
  denied_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" done \
      --note-f "$assigned_id" 999 --agent forged 2>&1
  )"
  denied_rc=$?
  set -e
  [[ "$denied_rc" -ne 0 ]] || smoke_fail "abbrev smuggling: gateway should refuse abbreviated --note-f"
  smoke_assert_contains "$denied_out" "queue gateway denied" "abbrev smuggling: gateway emits denial"

  # Sanity: the assigned task is still claimed (not flipped to done).
  show_out="$(BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$assigned_id" --format shell)"
  smoke_assert_not_contains "$show_out" "TASK_STATUS=done" "abbrev smuggling: real task must not be marked done"

  # Positive case: full --note flag still works for the legitimate owner.
  set +e
  accept_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" done \
      "$assigned_id" --agent worker-a --note "abbrev smoke complete" 2>&1
  )"
  accept_rc=$?
  set -e
  [[ "$accept_rc" -eq 0 ]] || smoke_fail "abbrev smuggling: full --note flag must still succeed (rc=$accept_rc out=$accept_out)"
  show_out="$(BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$assigned_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_STATUS=done" "abbrev smuggling: full-flag done succeeds"

  queue_gateway_stop_socket_server
}

# r2 finding 8b: peer disconnect / partial frame must NOT kill the
# listener. Open a socket, write a partial JSON, close. Then verify a
# subsequent valid request still succeeds.
queue_gateway_accept_loop_survival() {
  local socket_path server_log good_out probe_rc create_out task_id

  queue_gateway_stop_socket_server
  queue_gateway_socket_env
  BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" ensure-runtime --bridge-home "$BRIDGE_HOME" --strict >/dev/null
  socket_path="$(queue_gateway_socket_path)"
  server_log="$SMOKE_TMP_ROOT/queue-gateway-survival.log"
  queue_gateway_start_socket_server "$socket_path" "$server_log"

  set +e
  python3 - "$socket_path" <<'PY'
import socket
import sys

sock_type = getattr(socket, "SOCK_SEQPACKET", None)
if sock_type is None:
    raise SystemExit(0)
with socket.socket(socket.AF_UNIX, sock_type) as sock:
    sock.settimeout(3)
    sock.connect(sys.argv[1])
    # Partial / invalid JSON frame, then immediate close.
    sock.sendall(b'{"id":"partial","argv":["inb')
PY
  probe_rc=$?
  set -e
  [[ "$probe_rc" -eq 0 ]] || smoke_fail "accept-loop survival: partial-frame probe failed (rc=$probe_rc)"

  # Listener must still be alive and serving valid requests.
  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a --from requester \
      --title "survival proof" --body "after partial frame" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  smoke_assert_match "$task_id" '^[0-9]+$' "accept-loop survival: subsequent create returns task id"
  good_out="$(BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$good_out" "TASK_CREATED_BY=worker-a" "accept-loop survival: subsequent create rewrote actor"

  # Existing oversize coverage already lives in queue_gateway_socket_contract;
  # repeat a minimal version here to ensure both adversarial shapes leave the
  # listener alive.
  set +e
  python3 - "$socket_path" <<'PY'
import json
import socket
import sys

sock_type = getattr(socket, "SOCK_SEQPACKET", None)
if sock_type is None:
    raise SystemExit(0)
payload = {"id": "oversize2", "argv": ["inbox", "--agent", "x"], "padding": "x" * (2 * 1024 * 1024 + 16)}
with socket.socket(socket.AF_UNIX, sock_type) as sock:
    sock.settimeout(5)
    sock.connect(sys.argv[1])
    try:
        sock.sendall(json.dumps(payload).encode("utf-8"))
        sock.recv(4096)
    except OSError:
        pass
PY
  probe_rc=$?
  set -e
  [[ "$probe_rc" -eq 0 ]] || smoke_fail "accept-loop survival: oversize probe failed (rc=$probe_rc)"

  good_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" inbox --agent worker-a 2>&1
  )"
  smoke_assert_contains "$good_out" "$task_id" "accept-loop survival: inbox still serves after oversize probe"

  queue_gateway_stop_socket_server
}

# r2 finding 5: socket transport is fail-closed. With BRIDGE_GATEWAY_TRANSPORT=socket,
# a client whose listener is down must surface a recognizable error and
# return non-zero — there is no implicit fallback to file transport.
queue_gateway_socket_down_contract() {
  local socket_path down_out down_rc

  queue_gateway_stop_socket_server
  queue_gateway_socket_env
  python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" ensure-runtime --bridge-home "$BRIDGE_HOME" --strict >/dev/null
  socket_path="$(queue_gateway_socket_path)"
  # Socket file must NOT exist for this test.
  [[ ! -S "$socket_path" ]] || smoke_fail "fail-closed: pre-condition — socket file should not exist"

  set +e
  down_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" inbox --agent worker-a 2>&1
  )"
  down_rc=$?
  set -e
  [[ "$down_rc" -ne 0 ]] || smoke_fail "fail-closed: client must non-zero when listener is down"
  smoke_assert_contains "$down_out" "queue gateway socket unavailable" \
    "fail-closed: client emits recognizable unavailable error"
}

# r2 finding 2b: server-side ownership re-check is a defense-in-depth
# layer below the gateway authorizer. Running bridge-queue.py directly
# with BRIDGE_QUEUE_GATEWAY_SERVER=1 (simulating the server child) and
# an actor that does not own the task must be refused even though the
# gateway authorizer is bypassed.
queue_gateway_server_side_ownership_contract() {
  local create_out task_id deny_out deny_rc

  BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  create_out="$(
    BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a --from requester \
      --title "server side ownership" --body "owned by worker-a" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"

  # Cancel as a non-owner under the server flag must fail.
  set +e
  deny_out="$(
    BRIDGE_QUEUE_GATEWAY_SERVER=1 BRIDGE_GATEWAY_PROXY=0 \
      python3 "$SMOKE_REPO_ROOT/bridge-queue.py" cancel "$task_id" --actor outsider 2>&1
  )"
  deny_rc=$?
  set -e
  [[ "$deny_rc" -ne 0 ]] || smoke_fail "server-side recheck: cancel by non-owner must fail"
  smoke_assert_contains "$deny_out" "queue gateway server denied" \
    "server-side recheck: cancel surfaces second-line denial"

  # Update as a non-owner under the server flag must fail.
  set +e
  deny_out="$(
    BRIDGE_QUEUE_GATEWAY_SERVER=1 BRIDGE_GATEWAY_PROXY=0 \
      python3 "$SMOKE_REPO_ROOT/bridge-queue.py" update "$task_id" --actor outsider --note "x" 2>&1
  )"
  deny_rc=$?
  set -e
  [[ "$deny_rc" -ne 0 ]] || smoke_fail "server-side recheck: update by non-owner must fail"
  smoke_assert_contains "$deny_out" "queue gateway server denied" \
    "server-side recheck: update surfaces second-line denial"

  # Handoff as a non-owner under the server flag must fail.
  set +e
  deny_out="$(
    BRIDGE_QUEUE_GATEWAY_SERVER=1 BRIDGE_GATEWAY_PROXY=0 \
      python3 "$SMOKE_REPO_ROOT/bridge-queue.py" handoff "$task_id" --to other-agent --from outsider 2>&1
  )"
  deny_rc=$?
  set -e
  [[ "$deny_rc" -ne 0 ]] || smoke_fail "server-side recheck: handoff by non-owner must fail"
  smoke_assert_contains "$deny_out" "queue gateway server denied" \
    "server-side recheck: handoff surfaces second-line denial"

  # Sanity: the same operations succeed when the actor IS the assigned owner.
  BRIDGE_QUEUE_GATEWAY_SERVER=1 BRIDGE_GATEWAY_PROXY=0 \
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" cancel "$task_id" --actor worker-a --note "ok" >/dev/null
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "queue"
  smoke_run "queue lifecycle with stabilized body files" queue_lifecycle
  smoke_run "queue daemon-step nudge selection" queue_daemon_step_contract
  smoke_run "queue gateway runtime id contract" queue_gateway_runtime_id_contract
  # Socket transport is Linux-only fail-closed (SO_PEERCRED). On macOS /
  # BSD the listener refuses to start; skipping here keeps the rest of
  # the queue smoke suite green on operator workstations.
  if smoke_is_linux; then
    smoke_run "queue gateway socket peer auth contract" queue_gateway_socket_contract
    smoke_run "queue gateway socket peer ACL contract" queue_gateway_socket_acl_contract
    smoke_run "queue gateway runtime repair contract" queue_gateway_runtime_repair_contract
    smoke_run "queue gateway argv-rewriting hardening" queue_gateway_argv_rewriting_contract
    smoke_run "queue gateway argv abbreviation hardening" queue_gateway_argv_abbrev_smuggling_contract
    smoke_run "queue gateway accept-loop survival" queue_gateway_accept_loop_survival
    smoke_run "queue gateway socket-down fail-closed" queue_gateway_socket_down_contract
    smoke_run "queue gateway server-side ownership recheck" queue_gateway_server_side_ownership_contract
  else
    smoke_skip "queue gateway socket peer auth contract" "non-Linux"
    smoke_skip "queue gateway socket peer ACL contract" "non-Linux"
    smoke_skip "queue gateway runtime repair contract" "non-Linux"
    smoke_skip "queue gateway argv-rewriting hardening" "non-Linux"
    smoke_skip "queue gateway argv abbreviation hardening" "non-Linux"
    smoke_skip "queue gateway accept-loop survival" "non-Linux"
    smoke_skip "queue gateway socket-down fail-closed" "non-Linux"
    smoke_skip "queue gateway server-side ownership recheck" "non-Linux"
  fi
  smoke_log "passed"
}

main "$@"
