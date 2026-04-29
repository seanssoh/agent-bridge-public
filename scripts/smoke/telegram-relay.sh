#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="telegram-relay"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

FAKE_PID=""
RELAY_PID=""
RELAY_LOG=""

cleanup() {
  if [[ -n "$RELAY_PID" ]]; then
    kill "$RELAY_PID" >/dev/null 2>&1 || true
    wait "$RELAY_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$FAKE_PID" ]]; then
    kill "$FAKE_PID" >/dev/null 2>&1 || true
    wait "$FAKE_PID" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

wait_for_path() {
  local path="$1"
  local context="$2"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    [[ -e "$path" ]] && return 0
    sleep 0.1
  done
  if [[ -n "$RELAY_PID" ]]; then
    if kill -0 "$RELAY_PID" >/dev/null 2>&1; then
      printf '[smoke:%s][debug] relay pid %s is still running\n' "$SMOKE_NAME" "$RELAY_PID" >&2
    else
      printf '[smoke:%s][debug] relay pid %s is not running\n' "$SMOKE_NAME" "$RELAY_PID" >&2
    fi
  fi
  if [[ -n "$RELAY_LOG" && -f "$RELAY_LOG" ]]; then
    printf '[smoke:%s][debug] relay log follows:\n' "$SMOKE_NAME" >&2
    sed -n '1,120p' "$RELAY_LOG" >&2 || true
  fi
  smoke_fail "$context: timed out waiting for $path"
}

relay_rpc() {
  local socket_path="$1"
  local request_json="$2"
  python3 "$SMOKE_REPO_ROOT/lib/telegram-relay.py" rpc \
    --socket-path "$socket_path" \
    --request-json "$request_json"
}

assert_update_once() {
  local response="$1"
  local client="$2"
  python3 - "$response" "$client" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
client = sys.argv[2]
updates = payload.get("updates")
if not payload.get("ok"):
    raise SystemExit(f"{client}: recv failed: {payload}")
if len(updates) != 1:
    raise SystemExit(f"{client}: expected exactly one update, got {len(updates)}: {payload}")
update = updates[0]
if update.get("update_id") != 1:
    raise SystemExit(f"{client}: expected update_id=1, got {update.get('update_id')!r}")
if client not in update.get("delivered_to", []):
    raise SystemExit(f"{client}: delivered_to missing client: {update}")
PY
}

telegram_relay_rpc_surface() {
  local fake_py port_file updates_file sent_file token_file token_hash socket_path cursor_file
  local api_base relay_log response sent_count status_output

  fake_py="$SMOKE_TMP_ROOT/fake-telegram.py"
  port_file="$SMOKE_TMP_ROOT/fake-port"
  updates_file="$SMOKE_TMP_ROOT/updates.json"
  sent_file="$SMOKE_TMP_ROOT/sent.jsonl"
  token_file="$SMOKE_TMP_ROOT/token"
  relay_log="$SMOKE_TMP_ROOT/relay.stdout"
  RELAY_LOG="$relay_log"

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

  cat >"$updates_file" <<'JSON'
[
  {
    "update_id": 1,
    "message": {
      "message_id": 11,
      "chat": {"id": 12345},
      "text": "hello from fake telegram"
    }
  }
]
JSON
  : >"$sent_file"
  printf '%s\n' "123456:fake-token" >"$token_file"
  chmod 600 "$token_file"

  python3 "$fake_py" "$port_file" "$updates_file" "$sent_file" &
  FAKE_PID="$!"
  wait_for_path "$port_file" "fake Telegram server"
  api_base="http://127.0.0.1:$(cat "$port_file")"

  "$SMOKE_REPO_ROOT/agent-bridge" telegram-relay start \
    --token-file "$token_file" \
    --foreground \
    --api-base-url "$api_base" \
    --poll-timeout 1 >"$relay_log" 2>&1 &
  RELAY_PID="$!"

  token_hash="$(python3 "$SMOKE_REPO_ROOT/lib/telegram-relay.py" token-hash --token-file "$token_file")"
  socket_path="$BRIDGE_STATE_DIR/channels/telegram/${token_hash}.sock"
  cursor_file="$BRIDGE_STATE_DIR/channels/telegram/${token_hash}/cursor"
  wait_for_path "$socket_path" "relay socket"

  status_output="$("$SMOKE_REPO_ROOT/agent-bridge" telegram-relay status)"
  smoke_assert_contains "$status_output" "$token_hash" "telegram-relay status lists token hash"
  smoke_assert_contains "$status_output" "running=yes" "telegram-relay status reports running relay"

  response="$("$SMOKE_REPO_ROOT/agent-bridge" telegram-relay health --token-hash "$token_hash" --json)"
  smoke_assert_contains "$response" '"ok": true' "telegram-relay health"

  response="$(relay_rpc "$socket_path" '{"verb":"register","client_id":"client-a","channel_filter":{}}')"
  smoke_assert_contains "$response" '"ok": true' "client-a register"
  response="$(relay_rpc "$socket_path" '{"verb":"register","client_id":"client-b","channel_filter":{}}')"
  smoke_assert_contains "$response" '"ok": true' "client-b register"

  response="$(relay_rpc "$socket_path" '{"verb":"recv","client_id":"client-a","since_id":0,"timeout_seconds":5}')"
  assert_update_once "$response" "client-a"
  response="$(relay_rpc "$socket_path" '{"verb":"recv","client_id":"client-b","since_id":0,"timeout_seconds":5}')"
  assert_update_once "$response" "client-b"
  response="$(relay_rpc "$socket_path" '{"verb":"recv","client_id":"client-a","since_id":0,"timeout_seconds":0}')"
  smoke_assert_contains "$response" '"updates": []' "client-a dedupe"

  response="$(relay_rpc "$socket_path" '{"verb":"send_message","chat_id":12345,"text":"relay outbound","reply_to":11}')"
  smoke_assert_contains "$response" '"ok": true' "send_message RPC"
  sent_count="$(wc -l <"$sent_file" | tr -d ' ')"
  smoke_assert_eq "1" "$sent_count" "fake Telegram sendMessage call count"
  smoke_assert_contains "$(cat "$sent_file")" '"text": "relay outbound"' "fake Telegram sendMessage payload"

  kill "$RELAY_PID"
  wait "$RELAY_PID" >/dev/null 2>&1 || true
  RELAY_PID=""
  wait_for_path "$cursor_file" "relay cursor"
  smoke_assert_eq "1" "$(cat "$cursor_file")" "cursor persisted after SIGTERM"

  "$SMOKE_REPO_ROOT/agent-bridge" telegram-relay start \
    --token-file "$token_file" \
    --foreground \
    --api-base-url "$api_base" \
    --poll-timeout 1 >>"$relay_log" 2>&1 &
  RELAY_PID="$!"
  wait_for_path "$socket_path" "relay socket after restart"
  response="$(relay_rpc "$socket_path" '{"verb":"register","client_id":"client-c","channel_filter":{}}')"
  smoke_assert_contains "$response" '"ok": true' "client-c register after restart"
  response="$(relay_rpc "$socket_path" '{"verb":"recv","client_id":"client-c","since_id":0,"timeout_seconds":2}')"
  assert_update_once "$response" "client-c"

  "$SMOKE_REPO_ROOT/agent-bridge" telegram-relay stop --token-hash "$token_hash" >/dev/null
  wait "$RELAY_PID" >/dev/null 2>&1 || true
  RELAY_PID=""
}

main() {
  smoke_require_cmd python3
  TMPDIR=/tmp smoke_setup_bridge_home "tg"
  smoke_run "Telegram relay daemon RPC/fan-out/cursor smoke" telegram_relay_rpc_surface
  smoke_log "passed"
}

main "$@"
