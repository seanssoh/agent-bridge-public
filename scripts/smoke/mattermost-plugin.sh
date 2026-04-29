#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="mattermost-plugin"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

ensure_plugin_deps() {
  smoke_require_cmd bun
  if [[ ! -d "$SMOKE_REPO_ROOT/plugins/mattermost/node_modules/@modelcontextprotocol/sdk" ]]; then
    bun install --cwd "$SMOKE_REPO_ROOT/plugins/mattermost" --frozen-lockfile
  fi
}

mattermost_setup_writes_state() {
  local agent_dir="$BRIDGE_AGENT_HOME_ROOT/mm-agent"
  local mattermost_dir="$agent_dir/.mattermost"
  local out="$SMOKE_TMP_ROOT/setup.out"

  mkdir -p "$agent_dir"
  python3 "$SMOKE_REPO_ROOT/bridge-setup.py" mattermost \
    --agent mm-agent \
    --mattermost-dir "$mattermost_dir" \
    --url "http://127.0.0.1:8065" \
    --bot-token "fake-token" \
    --allow-from "user-a" \
    --channel "channel-a" \
    --require-mention \
    --mcp-binary "mattermost-mcp-server" \
    --skip-validate >"$out"

  smoke_assert_file_exists "$mattermost_dir/.env" "mattermost setup env"
  smoke_assert_file_exists "$mattermost_dir/access.json" "mattermost setup access"
  smoke_assert_file_exists "$agent_dir/.mcp.json" "mattermost setup mcp"
  smoke_assert_contains "$(cat "$mattermost_dir/.env")" "MATTERMOST_BOT_TOKEN=fake-token" "mattermost env token"
  smoke_assert_contains "$(cat "$out")" "write_status: ok" "mattermost setup status"

  python3 - "$mattermost_dir/access.json" "$agent_dir/.mcp.json" <<'PY'
import json
import sys
from pathlib import Path

access = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
mcp = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

assert access["dmPolicy"] == "allowlist"
assert access["allowFrom"] == ["user-a"]
assert access["channels"]["channel-a"]["requireMention"] is True
server = mcp["mcpServers"]["mattermost"]
assert server["command"] == "mattermost-mcp-server"
assert server["env"]["MM_SERVER_URL"] == "http://127.0.0.1:8065"
assert server["env"]["MM_ACCESS_TOKEN"] == "fake-token"
PY
}

mattermost_plugin_builds() {
  ensure_plugin_deps
  bun build "$SMOKE_REPO_ROOT/plugins/mattermost/server.ts" \
    --target=bun \
    --outfile "$SMOKE_TMP_ROOT/mattermost-server.js" >/dev/null
  smoke_assert_file_exists "$SMOKE_TMP_ROOT/mattermost-server.js" "mattermost bun build output"
}

mattermost_invalid_routes_fail_fast() {
  local routes="$SMOKE_TMP_ROOT/routes.json"
  local out="$SMOKE_TMP_ROOT/routes.out"
  local err="$SMOKE_TMP_ROOT/routes.err"
  local status

  ensure_plugin_deps
  printf '{"not":"an array"}\n' >"$routes"

  set +e
  MATTERMOST_BOT_ROUTES="$routes" \
    MATTERMOST_STATE_DIR="$SMOKE_TMP_ROOT/mm-state" \
    BRIDGE_HOME="$SMOKE_REPO_ROOT" \
    bun "$SMOKE_REPO_ROOT/plugins/mattermost/server.ts" >"$out" 2>"$err"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    smoke_fail "invalid MATTERMOST_BOT_ROUTES: expected non-zero exit, got 0"
  fi
  smoke_assert_contains "$(cat "$err")" "must contain a JSON array" "invalid routes error"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "mattermost-plugin"
  smoke_run "setup writes env/access/mcp state" mattermost_setup_writes_state
  smoke_run "plugin builds with bundled dependencies" mattermost_plugin_builds
  smoke_run "invalid bot routes fail fast" mattermost_invalid_routes_fail_fast
  smoke_log "passed"
}

main "$@"
