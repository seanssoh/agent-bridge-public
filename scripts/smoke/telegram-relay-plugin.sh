#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="telegram-relay-plugin"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

FAKE_PID=""
RELAY_PID=""
PLUGIN_A_PID=""
PLUGIN_B_PID=""
RELAY_LOG=""
PLUGIN_A_LOG=""
PLUGIN_B_LOG=""
PLUGIN_A_READY=""
PLUGIN_B_READY=""
URGENT_LOG=""
API_BASE=""

cleanup_pid() {
  local pid="$1"
  if [[ -n "$pid" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  cleanup_pid "$PLUGIN_A_PID"
  cleanup_pid "$PLUGIN_B_PID"
  cleanup_pid "$RELAY_PID"
  cleanup_pid "$FAKE_PID"
  smoke_cleanup_temp_root
}
trap cleanup EXIT

dump_logs() {
  local label="$1"
  local file
  printf '[smoke:%s][debug] %s\n' "$SMOKE_NAME" "$label" >&2
  for file in "$RELAY_LOG" "$PLUGIN_A_LOG" "$PLUGIN_B_LOG"; do
    [[ -n "$file" && -f "$file" ]] || continue
    printf '[smoke:%s][debug] --- %s ---\n' "$SMOKE_NAME" "$file" >&2
    sed -n '1,160p' "$file" >&2 || true
  done
  if [[ -n "$URGENT_LOG" && -f "$URGENT_LOG" ]]; then
    printf '[smoke:%s][debug] --- %s ---\n' "$SMOKE_NAME" "$URGENT_LOG" >&2
    sed -n '1,120p' "$URGENT_LOG" >&2 || true
  fi
}

wait_for_path() {
  local path="$1"
  local context="$2"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    [[ -e "$path" ]] && return 0
    sleep 0.1
  done
  dump_logs "$context timed out"
  smoke_fail "$context: timed out waiting for $path"
}

wait_for_pid_exit() {
  local pid="$1"
  local context="$2"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  dump_logs "$context timed out"
  smoke_fail "$context: timed out waiting for pid $pid to exit"
}

relay_rpc() {
  local socket_path="$1"
  local request_json="$2"
  python3 "$SMOKE_REPO_ROOT/lib/telegram-relay.py" rpc \
    --socket-path "$socket_path" \
    --request-json "$request_json"
}

urgent_count() {
  local agent="$1"
  local text="$2"
  python3 - "$URGENT_LOG" "$agent" "$text" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
agent = sys.argv[2]
text = sys.argv[3]
if not path.exists():
    print(0)
    raise SystemExit
count = 0
for raw in path.read_text(encoding="utf-8").splitlines():
    parts = raw.split("\t", 2)
    if len(parts) == 3 and parts[0] == "urgent" and parts[1] == agent and text in parts[2]:
        count += 1
print(count)
PY
}

wait_for_urgent() {
  local agent="$1"
  local text="$2"
  local context="$3"
  local deadline=$((SECONDS + 12))
  local count
  while (( SECONDS < deadline )); do
    count="$(urgent_count "$agent" "$text")"
    if (( count >= 1 )); then
      return 0
    fi
    sleep 0.2
  done
  dump_logs "$context timed out"
  smoke_fail "$context: expected urgent dispatch for agent=$agent text=$text"
}

assert_urgent_count_eq() {
  local expected="$1"
  local agent="$2"
  local text="$3"
  local context="$4"
  local count
  count="$(urgent_count "$agent" "$text")"
  smoke_assert_eq "$expected" "$count" "$context"
}

write_updates() {
  local path="$1"
  local body="$2"
  local tmp="${path}.tmp"
  printf '%s\n' "$body" >"$tmp"
  mv "$tmp" "$path"
}

write_plugin_state() {
  local state_dir="$1"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "123456:fake-token" >"$state_dir/.env"
  chmod 600 "$state_dir/.env"
  cat >"$state_dir/access.json" <<'JSON'
{
  "dmPolicy": "allowlist",
  "allowFrom": ["12345"],
  "defaultChatId": "12345",
  "groups": {},
  "pending": {}
}
JSON
  chmod 600 "$state_dir/access.json"
}

ensure_plugin_deps() {
  smoke_require_cmd bun
  if [[ ! -d "$SMOKE_REPO_ROOT/plugins/telegram-relay/node_modules/@modelcontextprotocol/sdk" ]]; then
    bun install --cwd "$SMOKE_REPO_ROOT/plugins/telegram-relay" --frozen-lockfile
  fi
}

start_fake_telegram() {
  local fake_py="$SMOKE_TMP_ROOT/fake-telegram.py"
  local port_file="$SMOKE_TMP_ROOT/fake-port"
  local updates_file="$1"
  local sent_file="$2"

  cat >"$fake_py" <<'PY'
#!/usr/bin/env python3
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

port_file = Path(sys.argv[1])
updates_file = Path(sys.argv[2])
sent_file = Path(sys.argv[3])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _fmt, *_args):
        return

    def _write(self, payload, status=200):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if not parsed.path.endswith("/getUpdates"):
            self._write({"ok": False, "description": "not found"}, 404)
            return
        query = urllib.parse.parse_qs(parsed.query)
        offset = int(query.get("offset", ["0"])[0])
        updates = json.loads(updates_file.read_text(encoding="utf-8"))
        result = [item for item in updates if int(item.get("update_id", 0)) >= offset]
        self._write({"ok": True, "result": result})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if not parsed.path.endswith("/sendMessage"):
            self._write({"ok": False, "description": "not found"}, 404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        with sent_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(body, sort_keys=True) + "\n")
        self._write({"ok": True, "result": {"message_id": 42, **body}})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
  chmod +x "$fake_py"
  python3 "$fake_py" "$port_file" "$updates_file" "$sent_file" &
  FAKE_PID="$!"
  wait_for_path "$port_file" "fake Telegram server"
  API_BASE="http://127.0.0.1:$(cat "$port_file")"
}

start_relay() {
  local token_file="$1"
  local api_base="$2"

  "$SMOKE_REPO_ROOT/agent-bridge" telegram-relay start \
    --token-file "$token_file" \
    --foreground \
    --api-base-url "$api_base" \
    --poll-timeout 1 >"$RELAY_LOG" 2>&1 &
  RELAY_PID="$!"
}

start_plugin() {
  local __pid_var="$1"
  local state_dir="$2"
  local client_id="$3"
  local agent="$4"
  local ready_file="$5"
  local log_file="$6"

  TELEGRAM_STATE_DIR="$state_dir" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  AGENT_BRIDGE_CLI="$SMOKE_TMP_ROOT/fake-agent-bridge" \
  URGENT_LOG="$URGENT_LOG" \
  TELEGRAM_RELAY_CLIENT_ID="$client_id" \
  TELEGRAM_RELAY_AGENT="$agent" \
  TELEGRAM_RELAY_DISPATCH="urgent" \
  TELEGRAM_RELAY_DISABLE_MCP="1" \
  TELEGRAM_RELAY_RECV_TIMEOUT_SECONDS="1" \
  TELEGRAM_RELAY_READY_FILE="$ready_file" \
  bun "$SMOKE_REPO_ROOT/plugins/telegram-relay/server.ts" >"$log_file" 2>&1 &
  printf -v "$__pid_var" '%s' "$!"
}

telegram_relay_plugin_surface() {
  local updates_file sent_file token_file token_hash socket_path api_base
  local plugin_a_state plugin_b_state fake_agb reply_response sent_payload health

  updates_file="$SMOKE_TMP_ROOT/updates.json"
  sent_file="$SMOKE_TMP_ROOT/sent.jsonl"
  token_file="$SMOKE_TMP_ROOT/raw-token"
  RELAY_LOG="$SMOKE_TMP_ROOT/relay.log"
  PLUGIN_A_LOG="$SMOKE_TMP_ROOT/plugin-a.log"
  PLUGIN_B_LOG="$SMOKE_TMP_ROOT/plugin-b.log"
  PLUGIN_A_READY="$SMOKE_TMP_ROOT/plugin-a.ready"
  PLUGIN_B_READY="$SMOKE_TMP_ROOT/plugin-b.ready"
  URGENT_LOG="$SMOKE_TMP_ROOT/urgent.tsv"
  fake_agb="$SMOKE_TMP_ROOT/fake-agent-bridge"
  plugin_a_state="$SMOKE_TMP_ROOT/plugin-a-state"
  plugin_b_state="$SMOKE_TMP_ROOT/plugin-b-state"

  write_updates "$updates_file" '[{"update_id":1,"message":{"message_id":11,"chat":{"id":12345,"type":"private"},"from":{"id":12345,"username":"operator"},"text":"hello relay plugin"}}]'
  : >"$sent_file"
  : >"$URGENT_LOG"
  printf '%s\n' "123456:fake-token" >"$token_file"
  chmod 600 "$token_file"
  write_plugin_state "$plugin_a_state"
  write_plugin_state "$plugin_b_state"

  cat >"$fake_agb" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${URGENT_LOG:?}"
printf '%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" >>"$URGENT_LOG"
SH
  chmod +x "$fake_agb"

  start_fake_telegram "$updates_file" "$sent_file"
  api_base="$API_BASE"
  start_relay "$token_file" "$api_base"

  token_hash="$(python3 "$SMOKE_REPO_ROOT/lib/telegram-relay.py" token-hash --token-file "$token_file")"
  socket_path="$BRIDGE_STATE_DIR/channels/telegram/${token_hash}.sock"
  wait_for_path "$socket_path" "relay socket"

  start_plugin PLUGIN_A_PID "$plugin_a_state" "plugin-a" "agent-a" "$PLUGIN_A_READY" "$PLUGIN_A_LOG"
  start_plugin PLUGIN_B_PID "$plugin_b_state" "plugin-b" "agent-b" "$PLUGIN_B_READY" "$PLUGIN_B_LOG"
  wait_for_path "$PLUGIN_A_READY" "plugin-a registration"
  wait_for_path "$PLUGIN_B_READY" "plugin-b registration"

  wait_for_urgent "agent-a" "hello relay plugin" "plugin-a inbound dispatch"
  wait_for_urgent "agent-b" "hello relay plugin" "plugin-b inbound dispatch"
  sleep 0.5
  assert_urgent_count_eq "1" "agent-a" "hello relay plugin" "plugin-a receives initial update once"
  assert_urgent_count_eq "1" "agent-b" "hello relay plugin" "plugin-b receives initial update once"

  reply_response="$(
    TELEGRAM_STATE_DIR="$plugin_a_state" \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    TELEGRAM_RELAY_DISABLE_MCP="1" \
    bun "$SMOKE_REPO_ROOT/plugins/telegram-relay/server.ts" \
      --smoke-tool reply \
      --args '{"chat_id":"12345","text":"relay plugin reply","reply_to":"11"}'
  )"
  smoke_assert_not_contains "$reply_response" '"isError":true' "reply tool succeeds"
  smoke_assert_contains "$reply_response" 'relay plugin reply' "reply tool response includes sent text"
  sent_payload="$(cat "$sent_file")"
  smoke_assert_contains "$sent_payload" '"chat_id": "12345"' "reply sendMessage chat id"
  smoke_assert_contains "$sent_payload" '"reply_to_message_id": 11' "reply sendMessage reply_to"
  smoke_assert_contains "$sent_payload" '"text": "relay plugin reply"' "reply sendMessage text"

  kill "$PLUGIN_B_PID"
  wait_for_pid_exit "$PLUGIN_B_PID" "plugin-b SIGTERM"
  wait "$PLUGIN_B_PID" >/dev/null 2>&1 || true
  PLUGIN_B_PID=""
  health="$(relay_rpc "$socket_path" '{"verb":"health"}')"
  smoke_assert_contains "$health" '"ok": true' "relay remains healthy after plugin SIGTERM"

  kill "$RELAY_PID"
  wait_for_pid_exit "$RELAY_PID" "relay restart setup"
  wait "$RELAY_PID" >/dev/null 2>&1 || true
  RELAY_PID=""
  write_updates "$updates_file" '[{"update_id":1,"message":{"message_id":11,"chat":{"id":12345,"type":"private"},"from":{"id":12345,"username":"operator"},"text":"hello relay plugin"}},{"update_id":2,"message":{"message_id":12,"chat":{"id":12345,"type":"private"},"from":{"id":12345,"username":"operator"},"text":"after daemon restart"}}]'
  start_relay "$token_file" "$api_base"
  wait_for_path "$socket_path" "relay socket after restart"
  wait_for_urgent "agent-a" "after daemon restart" "plugin-a reconnect after relay restart"
  assert_urgent_count_eq "1" "agent-a" "after daemon restart" "plugin-a receives post-restart update once"
}

main() {
  smoke_require_cmd python3
  TMPDIR=/tmp smoke_setup_bridge_home "tgrp"
  ensure_plugin_deps
  smoke_run "Telegram relay plugin daemon/client/reply smoke" telegram_relay_plugin_surface
  smoke_log "passed"
}

main "$@"
