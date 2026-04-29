#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="telegram-relay-setup"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

FAKE_PID=""
TOKEN_HASH=""

cleanup() {
  if [[ -n "$TOKEN_HASH" ]]; then
    "$SMOKE_REPO_ROOT/agent-bridge" telegram-relay stop --token-hash "$TOKEN_HASH" >/dev/null 2>&1 || true
  fi
  stop_fake_telegram
  smoke_cleanup_temp_root
}

stop_fake_telegram() {
  if [[ -n "$FAKE_PID" ]]; then
    kill "$FAKE_PID" >/dev/null 2>&1 || true
    wait "$FAKE_PID" >/dev/null 2>&1 || true
    FAKE_PID=""
  fi
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
  smoke_fail "$context: timed out waiting for $path"
}

mode_of() {
  local path="$1"
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    stat -c '%a' "$path"
  fi
}

relay_rpc() {
  local socket_path="$1"
  local request_json="$2"
  python3 "$SMOKE_REPO_ROOT/lib/telegram-relay.py" rpc \
    --socket-path "$socket_path" \
    --request-json "$request_json"
}

assert_plugin_status() {
  local expected="$1"
  local payload
  payload="$("$SMOKE_REPO_ROOT/agent-bridge" status --json)"
  python3 - "$payload" "$expected" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expected = sys.argv[2]
agent = payload.get("agents", {}).get("test-agent")
if not isinstance(agent, dict):
    raise SystemExit("status JSON missing agents.test-agent")
plugins = agent.get("plugins")
if not isinstance(plugins, list):
    raise SystemExit(f"status JSON missing plugins list: {agent}")
relay = next((item for item in plugins if item.get("name") == "telegram-relay"), None)
if relay is None:
    raise SystemExit(f"status JSON missing telegram-relay plugin: {plugins}")
actual = relay.get("status")
if actual != expected:
    raise SystemExit(f"telegram-relay status: expected {expected}, got {actual}: {relay}")
PY
}

wait_for_recent_poll() {
  local socket_path="$1"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if relay_rpc "$socket_path" '{"verb":"health"}' | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("last_get_updates_ts", 0) else 1)' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  smoke_fail "relay health: timed out waiting for getUpdates poll"
}

write_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/test-agent"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "test-agent"
bridge_add_agent_id_if_missing "legacy-agent"
BRIDGE_AGENT_DESC["test-agent"]="Telegram relay setup smoke"
BRIDGE_AGENT_DESC["legacy-agent"]="Telegram legacy setup smoke"
BRIDGE_AGENT_ENGINE["test-agent"]="claude"
BRIDGE_AGENT_ENGINE["legacy-agent"]="claude"
BRIDGE_AGENT_SESSION["test-agent"]="telegram-relay-setup-smoke"
BRIDGE_AGENT_SESSION["legacy-agent"]="telegram-legacy-setup-smoke"
BRIDGE_AGENT_WORKDIR["test-agent"]="$workdir"
BRIDGE_AGENT_WORKDIR["legacy-agent"]="$BRIDGE_AGENT_HOME_ROOT/legacy-agent"
BRIDGE_AGENT_LAUNCH_CMD["test-agent"]="claude"
BRIDGE_AGENT_LAUNCH_CMD["legacy-agent"]="claude"
BRIDGE_AGENT_LOOP["test-agent"]=0
BRIDGE_AGENT_LOOP["legacy-agent"]=0
BRIDGE_AGENT_CONTINUE["test-agent"]=0
BRIDGE_AGENT_CONTINUE["legacy-agent"]=0
BRIDGE_AGENT_CHANNELS["test-agent"]="plugin:telegram@claude-plugins-official"
BRIDGE_AGENT_CHANNELS["legacy-agent"]="plugin:telegram-relay@agent-bridge"
EOF
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/legacy-agent"
}

write_plugin_registry() {
  export BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$SMOKE_TMP_ROOT/installed_plugins.json"
  cat >"$BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE" <<EOF
{
  "version": 1,
  "plugins": {
    "telegram@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "$SMOKE_TMP_ROOT/telegram-plugin",
        "version": "0.1.0"
      }
    ],
    "telegram-relay@agent-bridge": [
      {
        "scope": "user",
        "installPath": "$SMOKE_REPO_ROOT/plugins/telegram-relay",
        "version": "0.1.0"
      }
    ]
  }
}
EOF
}

start_fake_telegram() {
  local fake_py="$SMOKE_TMP_ROOT/fake-telegram.py"
  local port_file="$SMOKE_TMP_ROOT/fake-port"

  cat >"$fake_py" <<'PY'
#!/usr/bin/env python3
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

port_file = Path(sys.argv[1])

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
        if parsed.path.endswith("/getUpdates"):
            self._write({"ok": True, "result": []})
            return
        if parsed.path.endswith("/getMe"):
            self._write({"ok": True, "result": {"id": 42, "username": "setup_smoke_bot"}})
            return
        self._write({"ok": False, "description": "not found"}, 404)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
  chmod +x "$fake_py"
  python3 "$fake_py" "$port_file" >"$SMOKE_TMP_ROOT/fake-telegram.log" 2>&1 &
  FAKE_PID="$!"
  wait_for_path "$port_file" "fake Telegram server"
  printf 'http://127.0.0.1:%s' "$(cat "$port_file")"
}

telegram_relay_setup_flow() {
  local api_base setup_output telegram_dir env_file access_file relay_token tokens_file socket_path roster_text

  api_base="$(start_fake_telegram)"
  # Default flip (since v0.6.39): no --use-relay flag should still land on relay path.
  "$SMOKE_REPO_ROOT/agent-bridge" setup telegram test-agent \
    --token "123456:fake-token" \
    --allow-from "111111" \
    --default-chat "222222" \
    --skip-validate \
    --skip-send-test \
    --yes \
    --api-base-url "$api_base" >"$SMOKE_TMP_ROOT/setup.out"
  setup_output="$(cat "$SMOKE_TMP_ROOT/setup.out")"
  smoke_assert_contains "$setup_output" "relay_enabled: yes" "setup defaults to relay (no flag)"

  telegram_dir="$BRIDGE_AGENT_HOME_ROOT/test-agent/.telegram"
  env_file="$telegram_dir/.env"
  access_file="$telegram_dir/access.json"
  relay_token="$telegram_dir/relay-token"
  tokens_file="$BRIDGE_STATE_DIR/channels/telegram/tokens.list"

  smoke_assert_file_exists "$env_file" "setup writes Telegram .env"
  smoke_assert_file_exists "$access_file" "setup writes Telegram access.json"
  smoke_assert_file_exists "$relay_token" "setup writes relay token"
  smoke_assert_file_exists "$tokens_file" "setup writes tokens.list"
  smoke_assert_eq "600" "$(mode_of "$env_file")" ".env mode"
  smoke_assert_eq "600" "$(mode_of "$relay_token")" "relay-token mode"
  smoke_assert_eq "600" "$(mode_of "$tokens_file")" "tokens.list mode"
  smoke_assert_contains "$(cat "$env_file")" "TELEGRAM_BOT_TOKEN=123456:fake-token" ".env token value"
  smoke_assert_eq "123456:fake-token" "$(cat "$relay_token")" "relay-token raw value"

  TOKEN_HASH="$(python3 "$SMOKE_REPO_ROOT/lib/telegram-relay.py" token-hash --token-file "$relay_token")"
  smoke_assert_contains "$(cat "$tokens_file")" "$TOKEN_HASH" "tokens.list token hash"
  smoke_assert_contains "$(cat "$tokens_file")" "$relay_token" "tokens.list token path"

  roster_text="$(cat "$BRIDGE_ROSTER_LOCAL_FILE")"
  smoke_assert_contains "$roster_text" 'BRIDGE_AGENT_CHANNELS["test-agent"]="plugin:telegram-relay@agent-bridge"' "roster relay channel registration"
  smoke_assert_contains "$roster_text" 'BRIDGE_TELEGRAM_RELAY_ENABLED="1"' "daemon relay enable flag"
  smoke_assert_contains "$roster_text" "--dangerously-load-development-channels" "relay setup adds development channel launch flag"

  assert_plugin_status "daemon-down"

  BRIDGE_TELEGRAM_API_BASE_URL="$api_base" bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" sync >/dev/null
  socket_path="$BRIDGE_STATE_DIR/channels/telegram/${TOKEN_HASH}.sock"
  wait_for_path "$socket_path" "relay socket after daemon sync"
  wait_for_recent_poll "$socket_path"
  relay_rpc "$socket_path" '{"verb":"register","client_id":"setup-smoke","channel_filter":{}}' >/dev/null
  assert_plugin_status "connected"

  mv "$tokens_file" "$tokens_file.bak"
  assert_plugin_status "not-supervised"
  mv "$tokens_file.bak" "$tokens_file"
}

telegram_no_relay_opt_out_replaces_channel() {
  local api_base setup_output roster_text conflict_output

  api_base="$(start_fake_telegram)"
  "$SMOKE_REPO_ROOT/agent-bridge" setup telegram legacy-agent \
    --token "654321:legacy-token" \
    --allow-from "333333" \
    --default-chat "444444" \
    --no-relay \
    --skip-validate \
    --skip-send-test \
    --yes \
    --api-base-url "$api_base" >"$SMOKE_TMP_ROOT/no-relay.out"
  setup_output="$(cat "$SMOKE_TMP_ROOT/no-relay.out")"
  smoke_assert_contains "$setup_output" "relay_enabled: no" "--no-relay reports legacy mode"

  roster_text="$(cat "$BRIDGE_ROSTER_LOCAL_FILE")"
  smoke_assert_contains "$roster_text" 'BRIDGE_AGENT_CHANNELS["legacy-agent"]="plugin:telegram@claude-plugins-official"' "--no-relay replaces relay channel with legacy channel"
  smoke_assert_not_contains "$roster_text" 'BRIDGE_AGENT_CHANNELS["legacy-agent"]="plugin:telegram-relay@agent-bridge"' "--no-relay removes relay channel registration"

  if conflict_output="$("$SMOKE_REPO_ROOT/agent-bridge" setup telegram legacy-agent \
      --token "654321:legacy-token" \
      --allow-from "333333" \
      --use-relay \
      --no-relay \
      --skip-validate \
      --skip-send-test \
      --yes \
      --api-base-url "$api_base" 2>&1)"; then
    smoke_fail "--use-relay and --no-relay should be mutually exclusive"
  fi
  smoke_assert_contains "$conflict_output" "not allowed with argument" "relay flag conflict surfaces argparse error"
  stop_fake_telegram
}

main() {
  smoke_require_cmd python3
  TMPDIR=/tmp smoke_setup_bridge_home "tgsetup"
  write_roster
  write_plugin_registry
  smoke_run "Telegram --no-relay opt-out replaces relay channel" telegram_no_relay_opt_out_replaces_channel
  smoke_run "Telegram relay setup lifecycle/status smoke (default flip)" telegram_relay_setup_flow
  smoke_log "passed"
}

main "$@"
