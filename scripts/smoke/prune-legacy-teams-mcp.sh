#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="prune-legacy-teams-mcp"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

main() {
  smoke_setup_bridge_home "prune-legacy-teams-mcp"

  local agent_root="$SMOKE_TMP_ROOT/agents/dev_mun"
  local workdir="$agent_root/workdir"
  mkdir -p "$workdir"

  cat >"$agent_root/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "teams": {
      "command": "bun",
      "args": ["--cwd", "/home/ec2-user/.agent-bridge/plugins/teams", "--no-install", "/home/ec2-user/.agent-bridge/plugins/teams/server.ts"],
      "env": {
        "TEAMS_STATE_DIR": "/tmp/.teams",
        "BRIDGE_AGENT_ID": "dev_mun"
      }
    },
    "memkraft": {
      "command": "python3",
      "args": ["-m", "memkraft.mcp"]
    }
  }
}
JSON

  cat >"$workdir/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "teams": {
      "command": "custom-teams",
      "args": ["server.ts"]
    }
  }
}
JSON

  python3 "$SMOKE_REPO_ROOT/scripts/python-helpers/prune-legacy-teams-mcp.py" \
    --agent dev_mun \
    --workdir "$workdir" \
    --agent-root "$agent_root" >/tmp/prune-legacy-teams-mcp.out

  python3 - "$agent_root/.mcp.json" "$workdir/.mcp.json" <<'PY'
import json
import sys
root = json.loads(open(sys.argv[1], encoding="utf-8").read())
work = json.loads(open(sys.argv[2], encoding="utf-8").read())
assert "teams" not in root["mcpServers"], root
assert "memkraft" in root["mcpServers"], root
assert "teams" in work["mcpServers"], work
PY

  smoke_log "passed"
}

main "$@"
